#!/bin/bash
# ================================================================================
# File: proxy.sh
#
# Purpose:
#   MCP stdio proxy for the Cost Explorer serverless API. Reads JSON-RPC 2.0
#   messages from stdin, signs POST requests to API Gateway with AWS SigV4,
#   and writes tool results back to stdout. The AI caller sees a local MCP
#   server — the Lambda backend is fully transparent.
#
# Dependencies:
#   bash 4+, curl, jq, openssl
#
# Required environment variables:
#   MCP_ACCESS_KEY_ID      IAM access key for the cost-mcp-proxy user
#   MCP_SECRET_ACCESS_KEY  IAM secret key for the cost-mcp-proxy user
#   MCP_API_ENDPOINT       API Gateway invoke URL (no trailing slash)
#   MCP_REGION             AWS region (default: us-east-1)
# ================================================================================

set -euo pipefail

# ================================================================================
# Configuration
# ================================================================================

ACCESS_KEY="${MCP_ACCESS_KEY_ID:?MCP_ACCESS_KEY_ID is required}"
SECRET_KEY="${MCP_SECRET_ACCESS_KEY:?MCP_SECRET_ACCESS_KEY is required}"
API_ENDPOINT="${MCP_API_ENDPOINT:?MCP_API_ENDPOINT is required}"
REGION="${MCP_REGION:-us-east-1}"

# ================================================================================
# Tool registry
# ================================================================================

declare -A TOOL_ROUTES
TOOL_ROUTES["get_month_to_date_cost"]="/cost/month-to-date"
TOOL_ROUTES["get_cost_by_service"]="/cost/by-service"
TOOL_ROUTES["compare_this_month_to_last_month"]="/cost/compare-months"
TOOL_ROUTES["get_daily_cost_trend"]="/cost/daily-trend"
TOOL_ROUTES["find_top_cost_drivers"]="/cost/top-drivers"
TOOL_ROUTES["forecast_month_end_cost"]="/cost/forecast"

# Static tool schema list — all tools take no parameters.
TOOLS_JSON='[
  {"name":"get_month_to_date_cost","description":"Returns total AWS spend from the first of this month through today.","inputSchema":{"type":"object","properties":{}}},
  {"name":"get_cost_by_service","description":"Returns month-to-date AWS spend broken down by service, sorted descending.","inputSchema":{"type":"object","properties":{}}},
  {"name":"compare_this_month_to_last_month","description":"Compares this month MTD spend against last month full total.","inputSchema":{"type":"object","properties":{}}},
  {"name":"get_daily_cost_trend","description":"Returns day-by-day AWS spend for the current month with running totals.","inputSchema":{"type":"object","properties":{}}},
  {"name":"find_top_cost_drivers","description":"Returns the top 10 AWS services by spend this month with percentage share.","inputSchema":{"type":"object","properties":{}}},
  {"name":"forecast_month_end_cost","description":"Forecasts remaining AWS spend through end of month with an 80% confidence range.","inputSchema":{"type":"object","properties":{}}}
]'

# ================================================================================
# SigV4 signing helpers
# ================================================================================

sha256_hex() {
    echo -n "$1" | openssl dgst -sha256 -hex | sed 's/^.*= //'
}

# HMAC-SHA256 with a plain string key — used for the first step of key derivation.
hmac_sha256_str() {
    local key="$1" data="$2"
    echo -n "$data" | openssl dgst -sha256 -mac HMAC -macopt "key:${key}" -hex | sed 's/^.*= //'
}

# HMAC-SHA256 with a hex-encoded binary key — used for subsequent derivation steps.
hmac_sha256_hex() {
    local hex_key="$1" data="$2"
    echo -n "$data" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${hex_key}" -hex | sed 's/^.*= //'
}

invoke_signed_request() {
    local url="$1"
    local body="${2:-{}}"
    local service="execute-api"

    local now date_stamp host uri_path
    now=$(date -u '+%Y%m%dT%H%M%SZ')
    date_stamp="${now:0:8}"
    host=$(echo "$url" | sed 's|https://||' | cut -d'/' -f1)
    uri_path=$(echo "$url" | sed "s|https://${host}||")

    # Payload hash — SHA-256 of the request body.
    local payload_hash
    payload_hash=$(sha256_hex "$body")

    # Canonical request — headers must be sorted alphabetically.
    local canonical_headers signed_headers canonical_request
    canonical_headers="content-type:application/json
host:${host}
x-amz-date:${now}
"
    signed_headers="content-type;host;x-amz-date"
    canonical_request="POST
${uri_path}

${canonical_headers}
${signed_headers}
${payload_hash}"

    # String to sign — binds to date, region, and service.
    local credential_scope cr_hash string_to_sign
    credential_scope="${date_stamp}/${REGION}/${service}/aws4_request"
    cr_hash=$(sha256_hex "$canonical_request")
    string_to_sign="AWS4-HMAC-SHA256
${now}
${credential_scope}
${cr_hash}"

    # Four-step HMAC key derivation chain.
    local k_date k_region k_service k_signing signature
    k_date=$(hmac_sha256_str    "AWS4${SECRET_KEY}" "$date_stamp")
    k_region=$(hmac_sha256_hex  "$k_date"           "$REGION")
    k_service=$(hmac_sha256_hex "$k_region"         "$service")
    k_signing=$(hmac_sha256_hex "$k_service"        "aws4_request")
    signature=$(hmac_sha256_hex "$k_signing"        "$string_to_sign")

    local auth_header="AWS4-HMAC-SHA256 Credential=${ACCESS_KEY}/${credential_scope}, SignedHeaders=${signed_headers}, Signature=${signature}"

    # Redirect curl stdin from /dev/null so it does not consume MCP messages.
    curl -s -X POST "$url" \
        -H "Authorization: ${auth_header}" \
        -H "x-amz-date: ${now}" \
        -H "Content-Type: application/json" \
        -d "$body" \
        < /dev/null
}

# ================================================================================
# JSON-RPC I/O helpers
# ================================================================================

send_response() {
    local id="$1" result="$2"
    jq -cn --argjson id "$id" --argjson result "$result" \
        '{"jsonrpc":"2.0","id":$id,"result":$result}'
}

send_error() {
    local id="$1" code="$2" message="$3"
    jq -cn --argjson id "$id" --argjson code "$code" --arg message "$message" \
        '{"jsonrpc":"2.0","id":$id,"error":{"code":$code,"message":$message}}'
}

# ================================================================================
# MCP method handlers
# ================================================================================

handle_initialize() {
    local id="$1"
    local result
    result=$(jq -cn '{
        "protocolVersion": "2025-11-25",
        "capabilities": {"tools": {}},
        "serverInfo": {"name": "cost-explorer-mcp", "version": "1.0.0"}
    }')
    send_response "$id" "$result"
}

handle_tools_list() {
    local id="$1"
    local result
    result=$(jq -cn --argjson tools "$TOOLS_JSON" '{"tools":$tools}')
    send_response "$id" "$result"
}

handle_tools_call() {
    local id="$1" params="$2"

    local tool_name
    tool_name=$(echo "$params" | jq -r '.name // empty')

    if [[ -z "$tool_name" ]]; then
        send_error "$id" -32602 "Missing required parameter: name"
        return
    fi

    local route="${TOOL_ROUTES[$tool_name]:-}"
    if [[ -z "$route" ]]; then
        send_error "$id" -32602 "Unknown tool: $tool_name"
        return
    fi

    local url="${API_ENDPOINT%/}${route}"
    local text

    if ! text=$(invoke_signed_request "$url" "{}"); then
        send_error "$id" -32603 "Tool invocation failed: curl error"
        return
    fi

    local result
    result=$(jq -cn --arg text "$text" '{"content":[{"type":"text","text":$text}]}')
    send_response "$id" "$result"
}

# ================================================================================
# Main loop
# ================================================================================

echo "NOTE: Cost Explorer MCP proxy started." >&2
echo "NOTE: Endpoint: ${API_ENDPOINT}  Region: ${REGION}" >&2

while IFS= read -r line; do
    # Strip carriage returns from Windows line endings.
    line="${line//$'\r'/}"
    [[ -z "$line" ]] && continue

    if ! echo "$line" | jq -e . > /dev/null 2>&1; then
        echo "WARN: Failed to parse JSON: $line" >&2
        continue
    fi

    method=$(echo "$line" | jq -r '.method // empty')
    id_raw=$(echo "$line" | jq -c '.id // null')
    params=$(echo "$line"  | jq -c '.params // {}')

    case "$method" in
        "initialize")
            [[ "$id_raw" != "null" ]] && handle_initialize "$id_raw"
            ;;
        "notifications/initialized")
            ;;
        "tools/list")
            [[ "$id_raw" != "null" ]] && handle_tools_list "$id_raw"
            ;;
        "tools/call")
            [[ "$id_raw" != "null" ]] && handle_tools_call "$id_raw" "$params"
            ;;
        *)
            [[ "$id_raw" != "null" ]] && send_error "$id_raw" -32601 "Method not found: $method"
            ;;
    esac
done

echo "NOTE: MCP proxy exiting." >&2
