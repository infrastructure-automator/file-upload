import logging
import os
import re
import uuid
from datetime import datetime

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient


# Blob metadata only allows ASCII header values; sanitize to be safe.
_INVALID = re.compile(r"[^\x20-\x7E]")


def _sanitize(value: str, limit: int = 1024) -> str:
    if not value:
        return ""
    return _INVALID.sub("?", value)[:limit]


def _client() -> BlobServiceClient:
    account = os.environ["STORAGE_ACCOUNT_NAME"]
    return BlobServiceClient(
        account_url=f"https://{account}.blob.core.windows.net",
        credential=DefaultAzureCredential(),
    )


def main(req: func.HttpRequest) -> func.HttpResponse:
    data = req.get_body()
    if not data:
        return func.HttpResponse("empty body", status_code=400)

    filename = req.headers.get("x-filename") or f"upload-{uuid.uuid4().hex}"
    blob_name = f"{datetime.utcnow().strftime('%Y%m%dT%H%M%S')}-{filename}"

    metadata = {
        "original_name": _sanitize(filename),
        "from_address":  _sanitize(req.headers.get("x-from", "")),
        "subject":       _sanitize(req.headers.get("x-subject", "")),
        "received":      _sanitize(req.headers.get("x-received", "")),
    }

    container = os.environ["BLOB_CONTAINER"]
    blob = _client().get_blob_client(container=container, blob=blob_name)
    blob.upload_blob(data, overwrite=True, metadata=metadata)

    logging.info("Uploaded %s (%d bytes) from=%s subject=%s",
                 blob_name, len(data), metadata["from_address"], metadata["subject"])
    return func.HttpResponse(f"stored as {blob_name}", status_code=200)
