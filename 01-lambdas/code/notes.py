"""
notes.py — Lambda handlers for the Notes CRUD API.

This module consolidates all five CRUD operations into a single Python file.
Each operation is exposed as a separate top-level handler function so that
Terraform can wire each one to its own Lambda function (and its own scoped
IAM role), while keeping the shared code — configuration, helpers, and the
DynamoDB client — in one place.

Handler → Lambda function → API Gateway route mapping:
    create_handler  →  create-note   →  POST   /notes
    list_handler    →  list-notes    →  GET    /notes
    get_handler     →  get-note      →  GET    /notes/{id}
    update_handler  →  update-note   →  PUT    /notes/{id}
    delete_handler  →  delete-note   →  DELETE /notes/{id}

Event format:
    All handlers receive an API Gateway v2 (HTTP API) payload format 2.0 event.
    Relevant fields used here:
        event["body"]                     — JSON request body (string)
        event["pathParameters"]["id"]     — path parameter extracted by API GW

Storage:
    Amazon DynamoDB with a composite key:
        PK: owner  (string, always "global" — no auth in this demo)
        SK: id     (string, UUID4)

Authentication:
    None. All endpoints are public. The "global" owner is hardcoded to keep
    the demo simple; a real implementation would derive the owner from a
    verified JWT or IAM identity.

Environment variables:
    NOTES_TABLE_NAME   The DynamoDB table name injected by Terraform at
                       deploy time via the Lambda environment block.
                       All five handlers read this variable.
"""

import json
import os
import uuid
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

# ---------------------------------------------------------------------------
# Module-level singletons
# ---------------------------------------------------------------------------

# DynamoDB table name sourced from the Lambda environment.  Validated at
# runtime by _table() rather than at import time so that import errors don't
# swallow the real error message.
TABLE_NAME = os.environ.get("NOTES_TABLE_NAME", "").strip()

# Hard-coded owner used as the DynamoDB partition key.  In a real multi-user
# system this would come from a verified authentication token; here every note
# belongs to the single synthetic owner "global".
OWNER = "global"

# DynamoDB resource client.  Initialised once per Lambda container so the
# connection is reused across warm invocations rather than re-established on
# every request.
dynamodb = boto3.resource("dynamodb")


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _response(status_code: int, body: dict) -> dict:
    """Build an API Gateway-compatible HTTP response dict.

    API Gateway v2 (HTTP API) expects Lambda to return a dict with at minimum
    `statusCode` and `body`.  The body must be a string, so the payload is
    JSON-serialised here.

    Args:
        status_code (int): The HTTP status code to return to the caller.
        body (dict):       The response payload — must be JSON-serialisable.

    Returns:
        dict: A response object with `statusCode`, `headers`, and `body`.
    """
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body)
    }


def _table():
    """Return the DynamoDB Table resource, validating the environment first.

    Raises:
        ValueError: If NOTES_TABLE_NAME is not set in the environment.

    Returns:
        boto3.resources.factory.dynamodb.Table: The DynamoDB table resource.
    """
    if not TABLE_NAME:
        raise ValueError("NOTES_TABLE_NAME environment variable is required")
    return dynamodb.Table(TABLE_NAME)


def _note_id(event: dict) -> str:
    """Extract the note ID from the API Gateway path parameters.

    API Gateway v2 injects path parameters into event["pathParameters"] as a
    dict.  This helper safely handles the case where the key is missing or
    pathParameters itself is None (e.g. in direct Lambda test invocations).

    Args:
        event (dict): The Lambda event object from API Gateway.

    Returns:
        str: The trimmed note ID, or an empty string if not present.
    """
    try:
        return event.get("pathParameters", {}).get("id", "").strip()
    except AttributeError:
        return ""


# ---------------------------------------------------------------------------
# CRUD handlers
# ---------------------------------------------------------------------------

def create_handler(event, context):
    """Create a new note and persist it to DynamoDB.

    Reads `title` and `note` from the JSON request body, generates a UUID4
    as the composite sort key, records timestamps, and writes the item using
    put_item with a ConditionExpression that prevents overwriting an existing
    document (collision guard — redundant given UUID4 but defensive).

    Request body (JSON):
        {
            "title": "string (required)",
            "note":  "string (required)"
        }

    DynamoDB item written:
        {
            "owner":      "global",
            "id":         "<uuid4>",
            "title":      "<title>",
            "note":       "<note>",
            "created_at": "<ISO-8601 UTC>",
            "updated_at": "<ISO-8601 UTC>"
        }

    Args:
        event   (dict): API Gateway v2 HTTP event.
        context (obj):  Lambda context object (unused).

    Returns:
        dict: 201 with {"id", "title", "note"} on success.
              400 if title or note are missing/empty or body is invalid JSON.
              500 if the DynamoDB write fails or the environment is misconfigured.
    """
    try:
        table = _table()
    except ValueError as exc:
        return _response(500, {"error": str(exc)})

    # Parse and validate the request body.  get_json equivalent for Lambda:
    # event["body"] is a plain JSON string (or None for bodyless requests).
    try:
        payload = json.loads(event.get("body", "{}"))
        title   = str(payload.get("title", "")).strip()
        note    = str(payload.get("note", "")).strip()
        if not title:
            raise ValueError("title is required")
        if not note:
            raise ValueError("note is required")
    except (ValueError, json.JSONDecodeError) as exc:
        return _response(400, {"error": f"Invalid request body: {str(exc)}"})

    # Generate a UUID4 that serves as both the DynamoDB sort key and the `id`
    # field embedded in the item, so callers can reference the note by ID
    # without needing to know the full composite key.
    note_id = str(uuid.uuid4())
    now     = datetime.now(timezone.utc).isoformat()

    item = {
        "owner":      OWNER,
        "id":         note_id,
        "title":      title,
        "note":       note,
        "created_at": now,
        "updated_at": now
    }

    try:
        # ConditionExpression guards against the astronomically unlikely case
        # where a newly generated UUID collides with an existing sort key.
        table.put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(#id)",
            ExpressionAttributeNames={"#id": "id"}
        )
    except ClientError:
        return _response(500, {"error": "Failed to create note"})

    # Return only the fields the client needs to reference the new note.
    return _response(201, {"id": note_id, "title": title, "note": note})


def list_handler(event, context):
    """List all notes belonging to the current owner.

    Queries DynamoDB using the partition key (owner = "global") to return
    every note for the demo user.  A Query is used rather than a Scan because
    the owner is known — this avoids a full table scan and stays efficient as
    the item count grows.

    Args:
        event   (dict): API Gateway v2 HTTP event (no fields consumed).
        context (obj):  Lambda context object (unused).

    Returns:
        dict: 200 with {"items": [<note>, ...]} where each note is the full
              DynamoDB item dict.
              500 if the query fails or the environment is misconfigured.
    """
    try:
        table = _table()
    except ValueError as exc:
        return _response(500, {"error": str(exc)})

    try:
        # Key() produces a boto3 condition expression; query() performs a
        # strongly consistent read against the partition key index.
        resp = table.query(KeyConditionExpression=Key("owner").eq(OWNER))
    except ClientError:
        return _response(500, {"error": "Failed to list notes"})

    return _response(200, {"items": resp.get("Items", [])})


def get_handler(event, context):
    """Retrieve a single note by its ID.

    Performs a direct get_item lookup using the composite key (owner, id).
    This is O(1) and strongly consistent — preferred over a query for
    single-item retrieval.

    Args:
        event   (dict): API Gateway v2 HTTP event.  The note ID is read from
                        event["pathParameters"]["id"].
        context (obj):  Lambda context object (unused).

    Returns:
        dict: 200 with the full note item dict on success.
              400 if no note ID is present in the path.
              404 if no item with the given ID exists in DynamoDB.
              500 if the read fails or the environment is misconfigured.
    """
    try:
        table = _table()
    except ValueError as exc:
        return _response(500, {"error": str(exc)})

    note_id = _note_id(event)
    if not note_id:
        return _response(400, {"error": "Note id is required"})

    try:
        resp = table.get_item(Key={"owner": OWNER, "id": note_id})
    except ClientError:
        return _response(500, {"error": "Failed to retrieve note"})

    # get_item returns an empty dict under "Item" when the key does not exist.
    item = resp.get("Item")
    if not item:
        return _response(404, {"error": "Note not found"})

    return _response(200, item)


def update_handler(event, context):
    """Update the title and body of an existing note.

    Uses update_item with a ConditionExpression to atomically verify the item
    exists and apply the field updates in a single request.  ReturnValues=
    ALL_NEW returns the full post-update item so the caller sees the authoritative
    state without a second round-trip.

    Args:
        event   (dict): API Gateway v2 HTTP event.  Note ID from path params;
                        updated fields from the JSON body.
        context (obj):  Lambda context object (unused).

    Returns:
        dict: 200 with the full updated item dict on success.
              400 if title/note are missing or the request body is invalid.
              404 if the ConditionExpression fails (item does not exist).
              500 if the update fails or the environment is misconfigured.
    """
    try:
        table = _table()
    except ValueError as exc:
        return _response(500, {"error": str(exc)})

    note_id = _note_id(event)
    if not note_id:
        return _response(400, {"error": "Note id is required"})

    try:
        payload = json.loads(event.get("body", "{}"))
        title   = str(payload.get("title", "")).strip()
        note    = str(payload.get("note", "")).strip()
        if not title:
            raise ValueError("title is required")
        if not note:
            raise ValueError("note is required")
    except (ValueError, json.JSONDecodeError) as exc:
        return _response(400, {"error": f"Invalid request body: {str(exc)}"})

    now = datetime.now(timezone.utc).isoformat()

    try:
        # update_item performs a partial write — only the named attributes are
        # changed; owner, id, and created_at are left untouched.
        # ExpressionAttributeNames avoids reserved-word conflicts for common
        # field names like "note" and "title".
        resp = table.update_item(
            Key={"owner": OWNER, "id": note_id},
            UpdateExpression="SET #title = :title, #note = :note, #updated_at = :ts",
            ConditionExpression="attribute_exists(#id)",
            ExpressionAttributeNames={
                "#id":         "id",
                "#title":      "title",
                "#note":       "note",
                "#updated_at": "updated_at"
            },
            ExpressionAttributeValues={
                ":title": title,
                ":note":  note,
                ":ts":    now
            },
            ReturnValues="ALL_NEW"
        )
    except ClientError as exc:
        # ConditionalCheckFailedException means attribute_exists(#id) was false
        # — the item does not exist — return 404 rather than 500.
        code = exc.response.get("Error", {}).get("Code", "")
        if code == "ConditionalCheckFailedException":
            return _response(404, {"error": "Note not found"})
        return _response(500, {"error": "Failed to update note"})

    return _response(200, resp.get("Attributes", {}))


def delete_handler(event, context):
    """Delete a note by its ID.

    Uses delete_item with a ConditionExpression so that attempting to delete a
    non-existent note returns 404 rather than silently succeeding (DynamoDB's
    delete_item is a no-op when the key does not exist without a condition).

    Args:
        event   (dict): API Gateway v2 HTTP event.  Note ID from path params.
        context (obj):  Lambda context object (unused).

    Returns:
        dict: 200 with {"message": "Note deleted"} on success.
              400 if no note ID is present in the path.
              404 if the ConditionExpression fails (item does not exist).
              500 if the delete fails or the environment is misconfigured.
    """
    try:
        table = _table()
    except ValueError as exc:
        return _response(500, {"error": str(exc)})

    note_id = _note_id(event)
    if not note_id:
        return _response(400, {"error": "Note id is required"})

    try:
        table.delete_item(
            Key={"owner": OWNER, "id": note_id},
            ConditionExpression="attribute_exists(#id)",
            ExpressionAttributeNames={"#id": "id"}
        )
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code == "ConditionalCheckFailedException":
            return _response(404, {"error": "Note not found"})
        return _response(500, {"error": "Failed to delete note"})

    return _response(200, {"message": "Note deleted"})
