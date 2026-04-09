import os
import re
from datetime import datetime, timedelta
from html import escape


_EMAIL_RE = re.compile(r"([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")


def _mask_part(part: str) -> str:
    if len(part) <= 1:
        return part
    if len(part) == 2:
        return part[0] + "*"
    return f"{part[0]}***{part[-1]}"


def _mask_email(value: str) -> str:
    """Replace each email in the string with f***t@d***n.tld style."""
    if not value:
        return ""

    def repl(m: "re.Match[str]") -> str:
        local, domain = m.group(1), m.group(2)
        host, _, tld = domain.rpartition(".")
        return f"{_mask_part(local)}@{_mask_part(host)}.{tld}"

    return _EMAIL_RE.sub(repl, value)

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, generate_blob_sas, BlobSasPermissions


PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Uploaded Files</title>
<style>
  body {{ font-family: system-ui, sans-serif; max-width: 720px; margin: 2rem auto; padding: 0 1rem; }}
  h1 {{ font-size: 1.4rem; }}
  table {{ border-collapse: collapse; width: 100%; }}
  th, td {{ text-align: left; padding: 0.4rem 0.6rem; border-bottom: 1px solid #eee; }}
  a {{ color: #0366d6; text-decoration: none; }}
  .empty {{ color: #888; font-style: italic; }}
</style></head>
<body>
<h1>Uploaded Files</h1>
<p>Email attachments sent to the configured mailbox appear here.</p>
{body}
</body></html>
"""


def main(req: func.HttpRequest) -> func.HttpResponse:
    account = os.environ["STORAGE_ACCOUNT_NAME"]
    container = os.environ["BLOB_CONTAINER"]
    cred = DefaultAzureCredential()
    svc = BlobServiceClient(account_url=f"https://{account}.blob.core.windows.net", credential=cred)

    # Get a user delegation key so we can mint short-lived SAS links
    start = datetime.utcnow() - timedelta(minutes=5)
    expiry = datetime.utcnow() + timedelta(hours=1)
    udk = svc.get_user_delegation_key(key_start_time=start, key_expiry_time=expiry)

    rows = []
    container_client = svc.get_container_client(container)
    for blob in container_client.list_blobs(include=["metadata"]):
        sas = generate_blob_sas(
            account_name=account,
            container_name=container,
            blob_name=blob.name,
            user_delegation_key=udk,
            permission=BlobSasPermissions(read=True),
            expiry=expiry,
        )
        url = f"https://{account}.blob.core.windows.net/{container}/{blob.name}?{sas}"
        size_kb = (blob.size or 0) / 1024
        meta = blob.metadata or {}
        display_name = meta.get("original_name") or blob.name
        from_addr    = _mask_email(meta.get("from_address", ""))
        subject      = meta.get("subject", "")
        rows.append(
            f"<tr>"
            f"<td><a href='{escape(url)}'>{escape(display_name)}</a></td>"
            f"<td>{escape(from_addr)}</td>"
            f"<td>{escape(subject)}</td>"
            f"<td>{size_kb:.1f} KB</td>"
            f"<td>{blob.last_modified:%Y-%m-%d %H:%M UTC}</td>"
            f"</tr>"
        )

    if rows:
        body = (
            "<table><tr>"
            "<th>File</th><th>From</th><th>Subject</th><th>Size</th><th>Uploaded</th>"
            "</tr>" + "".join(rows) + "</table>"
        )
    else:
        body = "<p class='empty'>No files uploaded yet.</p>"

    return func.HttpResponse(PAGE.format(body=body), mimetype="text/html", status_code=200)
