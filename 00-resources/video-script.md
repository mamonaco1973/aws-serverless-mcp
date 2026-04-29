# Video Script 

---

Do you need a clean way to run MCP backends on AWS — securely, without managing servers?

In this project, we implement a reusable MCP pattern using API Gateway, Lambda, and IAM authorization.

Follow along, and in minutes you’ll have a working backend that any AI client can use to call your serverless tools on AWS.

---

## Architecture

[ Full diagram ]

"Let's walk through the architecture before we build."

[ Highlight: Claude Desktop ]

We start with the AI client — in this case, Claude Desktop - issuing MCP tool calls over standard JSON-RPC.

[ Highlight: MCP Proxy ]

Those calls are handled by a lightweight MCP proxy.

The proxy acts as a bridge — translating local MCP requests into HTTPS calls.

[ Highlight: IAM Access Key ]

The proxy uses IAM credentials to sign every request, so nothing reaches AWS without authentication.

[ Highlight: API Gateway ]

API Gateway is the entry point for the backend.

Every route is protected using AWS IAM authorization.

---

[ Highlight: Lambda + costs.py ]

Behind API Gateway, each route invokes a Lambda function.


---

[ Highlight: Arrow to Cost Explorer ]

These functions call AWS services directly — here, the Cost Explorer API — to retrieve data.

---

[ Full diagram highlight ]

So from the AI’s perspective, this looks like a local tool server.

But in reality, every request is securely routed through API Gateway and executed in Lambda using IAM.

That’s the core pattern.
---

## Build the Code

[ Terminal — running ./apply.sh ]

"The whole deployment is one script — apply.sh. Two phases."

[ Terminal — Phase 1: Terraform apply in 01-lambdas ]

"Phase one: Terraform provisions DynamoDB, all five Lambda functions, their IAM roles, and the API Gateway — everything wired together with least-privilege permissions."

[ Terminal — API endpoint discovery and envsubst ]

"Between phases, the script looks up the API Gateway endpoint and injects it into the HTML template using envsubst."

[ Terminal — Phase 2: Terraform apply in 02-webapp ]

"Phase two: Terraform creates the S3 bucket and uploads the generated index.html. The site is live."

[ Terminal — validate.sh running smoke tests ]

"Finally, validate.sh runs an end-to-end smoke test — creates five notes, lists them, fetches one, updates it, and deletes it."

[ Terminal — deployment complete, URLs printed ]

"API URL. Website URL. Done."

---

## Build Results

[ Show API Gateway ]

1. An HTTP API Gateway is created as the entry point for all MCP tool calls.

---

[ Show Authorization Tab ]

2. All routes are secured with AWS IAM authorization, so every request must be IAM signed.

---

[ Show IAM User ]

3. A dedicated IAM user is created for the proxy with permission to invoke the API only.

---

[ Show Secrets Manager ]

4. Those credentials are stored in Secrets Manager and used by the proxy for request signing.

---

[ Show Lambdas ]

5. Multiple Lambda functions are deployed - one per tool, plus a discovery endpoint.

---

[ Show Python Code ]

6. All tool logic is implemented in Python, with each handler calling Cost Explorer.

---

[ Show Tools Registry ]

7.A central tool registry defines all available tools, and this  is used by the proxy for dynamic configuration.

---

[ Show Desktop JSON ]

8. Finally, example client configuration files are generated, allowing the MCP client to connect to the backend.
---

## Demo

[ Browser — Notes Demo, open DevTools → Network tab ]

"Open the web app — and the browser debugger so we can watch the API calls."

[ Refresh page — network calls visible ]

"When the app loads, it calls the list endpoint. No notes yet."

[ Clicking New — modal opens, typing a title, clicking Create ]

"Now let's create a new note by selecting New."

[ Show API working ]

"A POST to the API is made which returns an ID."

[ Clicking the note in the list ]

"The new note is also selected and the API loads the content."

[ Editing and clicking Save ]

"Now let's update the note and select Save."

[ Show network tab ]

"A PUT call is made — and the updated data is stored in DynamoDB."

[ Clicking Delete ]

"Now let's delete the note by selecting Delete."

[ Show network ]

"A DELETE call is made — and the note is removed."
 
[ Browser — empty list ]

"In this demo, we've now exercised every API endpoint."

---
