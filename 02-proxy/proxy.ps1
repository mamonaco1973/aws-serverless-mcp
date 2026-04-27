# ================================================================================
# File: proxy.ps1
#
# Purpose:
#   MCP stdio proxy for the Cost Explorer serverless API. Reads JSON-RPC 2.0
#   messages from stdin, signs POST requests to API Gateway with AWS SigV4,
#   and writes tool results back to stdout. The AI caller sees a local MCP
#   server — the Lambda backend is fully transparent.
#
# Required environment variables:
#   MCP_ACCESS_KEY_ID      IAM access key for the cost-mcp-proxy user
#   MCP_SECRET_ACCESS_KEY  IAM secret key for the cost-mcp-proxy user
#   MCP_API_ENDPOINT       API Gateway invoke URL (no trailing slash)
#   MCP_REGION             AWS region (default: us-east-1)
#
# Usage (Claude Desktop claude_desktop_config.json):
#   {
#     "mcpServers": {
#       "aws-costs": {
#         "command": "powershell",
#         "args": ["-File", "C:\\path\\to\\proxy.ps1"],
#         "env": {
#           "MCP_ACCESS_KEY_ID":     "...",
#           "MCP_SECRET_ACCESS_KEY": "...",
#           "MCP_API_ENDPOINT":      "https://xxx.execute-api.us-east-1.amazonaws.com"
#         }
#       }
#     }
#   }
# ================================================================================

# Force UTF-8 on both channels — MCP requires clean UTF-8 stdio.
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ================================================================================
# Configuration
# ================================================================================

$ACCESS_KEY   = $env:MCP_ACCESS_KEY_ID
$SECRET_KEY   = $env:MCP_SECRET_ACCESS_KEY
$API_ENDPOINT = $env:MCP_API_ENDPOINT
$REGION       = if ($env:MCP_REGION) { $env:MCP_REGION } else { "us-east-1" }

foreach ($name in @("MCP_ACCESS_KEY_ID", "MCP_SECRET_ACCESS_KEY", "MCP_API_ENDPOINT")) {
    if ([string]::IsNullOrEmpty((Get-Item "env:$name" -ErrorAction SilentlyContinue).Value)) {
        [Console]::Error.WriteLine("ERROR: Environment variable $name is required.")
        exit 1
    }
}

# ================================================================================
# Tool registry
# ================================================================================

# Maps MCP tool names to their API Gateway route paths.
$TOOL_ROUTES = @{
    "get_month_to_date_cost"           = "/cost/month-to-date"
    "get_cost_by_service"              = "/cost/by-service"
    "compare_this_month_to_last_month" = "/cost/compare-months"
    "get_daily_cost_trend"             = "/cost/daily-trend"
    "find_top_cost_drivers"            = "/cost/top-drivers"
    "forecast_month_end_cost"          = "/cost/forecast"
}

# Tool schemas exposed to the MCP client during initialize / tools/list.
# All tools take no input — inputSchema is an empty object.
$TOOLS = @(
    @{
        name        = "get_month_to_date_cost"
        description = "Returns total AWS spend from the first of this month through today."
        inputSchema = @{ type = "object"; properties = [ordered]@{} }
    }
    @{
        name        = "get_cost_by_service"
        description = "Returns month-to-date AWS spend broken down by service, sorted descending."
        inputSchema = @{ type = "object"; properties = [ordered]@{} }
    }
    @{
        name        = "compare_this_month_to_last_month"
        description = "Compares this month's MTD spend against last month's full total."
        inputSchema = @{ type = "object"; properties = [ordered]@{} }
    }
    @{
        name        = "get_daily_cost_trend"
        description = "Returns day-by-day AWS spend for the current month with running totals."
        inputSchema = @{ type = "object"; properties = [ordered]@{} }
    }
    @{
        name        = "find_top_cost_drivers"
        description = "Returns the top 10 AWS services by spend this month with percentage share."
        inputSchema = @{ type = "object"; properties = [ordered]@{} }
    }
    @{
        name        = "forecast_month_end_cost"
        description = "Forecasts remaining AWS spend through end of month with an 80% confidence range."
        inputSchema = @{ type = "object"; properties = [ordered]@{} }
    }
)

# ================================================================================
# SigV4 signing
# ================================================================================

function Invoke-HMACSHA256 {
    param([byte[]]$Key, [string]$Data)
    $hmac     = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $Key
    return $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Data))
}

function Invoke-SignedRequest {
    <#
    .SYNOPSIS
        Signs and executes an HTTP request using AWS Signature Version 4.

    .PARAMETER Method
        HTTP method (POST).

    .PARAMETER Url
        Full URL of the API Gateway endpoint.

    .PARAMETER Body
        Request body string. Defaults to an empty JSON object.
    #>
    param(
        [string]$Method,
        [string]$Url,
        [string]$Body = "{}"
    )

    $uri       = [System.Uri]$Url
    $now       = [DateTime]::UtcNow
    $amzDate   = $now.ToString("yyyyMMddTHHmmssZ")
    $dateStamp = $now.ToString("yyyyMMdd")
    $service   = "execute-api"

    # Hash the request body — required for the canonical request.
    $sha256      = [System.Security.Cryptography.SHA256]::Create()
    $payloadHash = [BitConverter]::ToString(
        $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Body))
    ).Replace("-", "").ToLower()

    # Canonical request — order of signed headers must be sorted alphabetically.
    $canonicalHeaders = "content-type:application/json`nhost:$($uri.Host)`nx-amz-date:$amzDate`n"
    $signedHeaders    = "content-type;host;x-amz-date"
    $canonicalRequest = "$Method`n$($uri.AbsolutePath)`n`n$canonicalHeaders`n$signedHeaders`n$payloadHash"

    # String to sign — binds the request to a specific date, region, and service.
    $credentialScope = "$dateStamp/$REGION/$service/aws4_request"
    $crHash          = [BitConverter]::ToString(
        $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canonicalRequest))
    ).Replace("-", "").ToLower()
    $stringToSign = "AWS4-HMAC-SHA256`n$amzDate`n$credentialScope`n$crHash"

    # Derive the signing key via a four-step HMAC chain.
    $kDate    = Invoke-HMACSHA256 -Key ([System.Text.Encoding]::UTF8.GetBytes("AWS4$SECRET_KEY")) -Data $dateStamp
    $kRegion  = Invoke-HMACSHA256 -Key $kDate    -Data $REGION
    $kService = Invoke-HMACSHA256 -Key $kRegion  -Data $service
    $kSigning = Invoke-HMACSHA256 -Key $kService -Data "aws4_request"
    $signature = [BitConverter]::ToString(
        (Invoke-HMACSHA256 -Key $kSigning -Data $stringToSign)
    ).Replace("-", "").ToLower()

    $headers = @{
        "Authorization" = "AWS4-HMAC-SHA256 Credential=$ACCESS_KEY/$credentialScope, SignedHeaders=$signedHeaders, Signature=$signature"
        "x-amz-date"    = $amzDate
        "Content-Type"  = "application/json"
    }

    # Use Invoke-WebRequest for predictable .Content string return regardless
    # of Content-Type — Lambda returns text/plain which Invoke-RestMethod
    # handles inconsistently across PS versions.
    $response = Invoke-WebRequest -Method $Method -Uri $Url -Headers $headers -Body $Body -UseBasicParsing
    return $response.Content
}

# ================================================================================
# JSON-RPC I/O helpers
# ================================================================================

function Send-Response {
    param($Id, $Result)
    $msg = [ordered]@{ jsonrpc = "2.0"; id = $Id; result = $Result } |
           ConvertTo-Json -Depth 10 -Compress
    [Console]::Out.WriteLine($msg)
    [Console]::Out.Flush()
}

function Send-Error {
    param($Id, [int]$Code, [string]$Message)
    $msg = [ordered]@{
        jsonrpc = "2.0"
        id      = $Id
        error   = @{ code = $Code; message = $Message }
    } | ConvertTo-Json -Depth 5 -Compress
    [Console]::Out.WriteLine($msg)
    [Console]::Out.Flush()
}

# ================================================================================
# MCP method handlers
# ================================================================================

function Invoke-Initialize {
    param($Id)
    Send-Response -Id $Id -Result ([ordered]@{
        protocolVersion = "2025-11-25"
        capabilities    = @{ tools = @{} }
        serverInfo      = @{ name = "cost-explorer-mcp"; version = "1.0.0" }
    })
}

function Invoke-ToolsList {
    param($Id)
    Send-Response -Id $Id -Result @{ tools = $TOOLS }
}

function Invoke-ToolsCall {
    param($Id, $Params)

    $toolName = $Params.name
    if ([string]::IsNullOrEmpty($toolName)) {
        Send-Error -Id $Id -Code -32602 -Message "Missing required parameter: name"
        return
    }

    $route = $TOOL_ROUTES[$toolName]
    if (-not $route) {
        Send-Error -Id $Id -Code -32602 -Message "Unknown tool: $toolName"
        return
    }

    try {
        $url    = "$($API_ENDPOINT.TrimEnd('/'))$route"
        $text   = Invoke-SignedRequest -Method "POST" -Url $url
        Send-Response -Id $Id -Result @{
            content = @(@{ type = "text"; text = $text })
        }
    }
    catch {
        [Console]::Error.WriteLine("ERROR: Tool $toolName failed: $_")
        Send-Error -Id $Id -Code -32603 -Message "Tool invocation failed: $($_.Exception.Message)"
    }
}

# ================================================================================
# Main loop
# ================================================================================

[Console]::Error.WriteLine("NOTE: Cost Explorer MCP proxy started.")
[Console]::Error.WriteLine("NOTE: Endpoint: $API_ENDPOINT  Region: $REGION")

while ($true) {
    $line = [Console]::In.ReadLine()

    # Null means stdin was closed (host process exited) — shut down cleanly.
    if ($null -eq $line) { break }

    $line = $line.Trim()
    if ([string]::IsNullOrEmpty($line)) { continue }

    try {
        $msg = $line | ConvertFrom-Json
    }
    catch {
        [Console]::Error.WriteLine("WARN: Failed to parse JSON: $line")
        continue
    }

    $method     = $msg.method
    $idProp     = $msg.PSObject.Properties["id"]
    $id         = if ($idProp)     { $idProp.Value }     else { $null }
    $paramsProp = $msg.PSObject.Properties["params"]
    $params     = if ($paramsProp) { $paramsProp.Value } else { $null }

    switch ($method) {
        "initialize"  { Invoke-Initialize -Id $id }
        "initialized" { }  # notification — no response
        "tools/list"  { Invoke-ToolsList -Id $id }
        "tools/call"  { Invoke-ToolsCall -Id $id -Params $params }
        default {
            if ($null -ne $id) {
                Send-Error -Id $id -Code -32601 -Message "Method not found: $method"
            }
        }
    }
}

[Console]::Error.WriteLine("NOTE: MCP proxy exiting.")
