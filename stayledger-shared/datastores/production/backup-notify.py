#!/usr/bin/env python3
"""SMTP notifier for StayLedger backup jobs — never logs credentials.

Visual tokens mirrored from stayledger-api email-theme.ts (cannot import TS).
"""
from __future__ import annotations

import html
import os
import re
import ssl
import smtplib
import sys
import time
from datetime import datetime
from email.message import EmailMessage
from pathlib import Path

SHARED = Path("/shared")
DONE = SHARED / "done"
STATUS = SHARED / "status"
SUBJECT_FILE = SHARED / "subject"
BODY_FILE = SHARED / "body"

# Mirrored from stayledger-api/src/modules/email/theme/email-theme.ts
NAVY = "#0B132B"
BLUE = "#1472FF"
CYAN = "#00C2E6"
AMBER = "#FF9F1C"
WHITE = "#FFFFFF"
GRAY50 = "#F1F3F6"
GRAY500 = "#667085"
GRAY900 = "#101828"
SUCCESS = "#16A34A"
ERROR = "#DC2626"
BORDER = "#D8DEE8"
FONT = "Inter, Arial, Helvetica, sans-serif"
FONT_DISPLAY = "Montserrat, Arial, Helvetica, sans-serif"

SECRET_PATTERNS = [
    re.compile(r"(?i)(AKIA[0-9A-Z]{16})"),
    re.compile(r"(?i)(ASIA[0-9A-Z]{16})"),
    re.compile(r"(?i)(aws_secret_access_key\s*[=:]\s*\S+)"),
    re.compile(r"(?i)(password\s*[=:]\s*\S+)"),
    re.compile(r"(?i)(postgres(?:ql)?://\S+)"),
    re.compile(r"(?i)(Bearer\s+[A-Za-z0-9._\-+/=]+)"),
    re.compile(r"(X-Amz-Credential=[^&\s]+)"),
    re.compile(r"(X-Amz-Signature=[^&\s]+)"),
]


def wait_done(timeout_s: int = 600) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if DONE.exists():
            return
        time.sleep(1)
    print("[notify] ERROR: timed out waiting for /shared/done", flush=True)
    sys.exit(1)


def redact(value: str) -> str:
    out = value
    for pat in SECRET_PATTERNS:
        out = pat.sub("[REDACTED]", out)
    return out


def parse_fields(body: str) -> list[tuple[str, str]]:
    rows: list[tuple[str, str]] = []
    for raw in body.splitlines():
        line = raw.strip()
        if not line or "=" not in line:
            continue
        if line.startswith("StayLedger ") or " SUCCEEDED" in line or " FAILED" in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = redact(value.strip())
        if key:
            rows.append((key, value))
    return rows


def human_label(key: str) -> str:
    labels = {
        "started_at": "Started (UTC)",
        "finished_at": "Finished (UTC)",
        "duration": "Duration",
        "dump": "Local dump path",
        "size": "Dump size",
        "retention_days": "Retention (days)",
        "node_path": "Node path",
        "object": "S3 object",
        "exit_code": "Exit code",
        "bucket": "Bucket",
        "prefix": "Prefix",
        "environment": "Environment",
        "backup_type": "Backup type",
        "service": "Service",
    }
    return labels.get(key, key.replace("_", " ").title())


def parse_iso(value: str) -> datetime | None:
    raw = value.strip()
    if not raw:
        return None
    try:
        if raw.endswith("Z"):
            raw = raw[:-1] + "+00:00"
        return datetime.fromisoformat(raw)
    except ValueError:
        return None


def format_duration(seconds: float) -> str:
    s = int(round(seconds))
    if s < 60:
        return f"{s}s"
    mins = s // 60
    rem = s % 60
    return f"{mins}m {rem}s" if rem else f"{mins}m"


def enrich_fields(fields: list[tuple[str, str]]) -> list[tuple[str, str]]:
    by_key = {k: v for k, v in fields}
    started = parse_iso(by_key.get("started_at", ""))
    finished = parse_iso(by_key.get("finished_at", ""))
    out = list(fields)
    if started and finished and "duration" not in by_key:
        insert_at = next(
            (i + 1 for i, (k, _) in enumerate(out) if k == "finished_at"),
            len(out),
        )
        out.insert(insert_at, ("duration", format_duration((finished - started).total_seconds())))
    if "environment" not in by_key:
        out.insert(0, ("environment", "Production"))
    if "service" not in by_key:
        out.insert(1, ("service", "StayLedger Postgres"))
    return out


def resolve_backup_type(fields: list[tuple[str, str]], headline: str) -> str:
    keys = {k for k, _ in fields}
    if "object" in keys or "S3" in headline or "off-node" in headline.lower():
        return "Off-site S3"
    if "dump" in keys or "local" in headline.lower():
        return "Local PVC"
    return "Database backup"


def build_subject(ok: bool, subject_tail: str) -> str:
    if ok:
        return "[StayLedger][Production] Database backup succeeded"
    return "[StayLedger][Production][ACTION REQUIRED] Database backup failed"


def build_summary(ok: bool, backup_type: str) -> str:
    if ok:
        if "S3" in backup_type:
            return "PostgreSQL production backup was uploaded to off-site S3 successfully."
        return "PostgreSQL production backup completed successfully on local storage."
    if "S3" in backup_type:
        return "The PostgreSQL production backup failed before or during upload to off-site storage."
    return "The PostgreSQL production backup failed on the local backup path."


def failure_actions() -> list[str]:
    return [
        "Review Kubernetes CronJob and container logs for the failed backup run.",
        "Verify disk capacity on the backup volume and S3 write permissions.",
        "Confirm the latest successful backup still meets the recovery point objective (RPO).",
        "Retry the backup job after addressing the root cause.",
    ]


def build_html(ok: bool, headline: str, fields: list[tuple[str, str]]) -> str:
    enriched = enrich_fields(fields)
    backup_type = resolve_backup_type(enriched, headline)
    if not any(k == "backup_type" for k, _ in enriched):
        enriched.insert(2, ("backup_type", backup_type))

    accent = SUCCESS if ok else ERROR
    badge_bg = "#DCFCE7" if ok else "#FEE2E2"
    badge_fg = SUCCESS if ok else ERROR
    badge_text = "Backup succeeded" if ok else "Backup failed — action required"
    summary = build_summary(ok, backup_type)

    row_html: list[str] = []
    for i, (k, v) in enumerate(enriched):
        bg = GRAY50 if i % 2 == 0 else WHITE
        row_html.append(
            '<tr style="background:'
            + bg
            + ';">'
            + '<td style="padding:12px 14px;font-size:14px;color:'
            + GRAY500
            + ";border-bottom:1px solid "
            + BORDER
            + ';width:38%;font-family:'
            + FONT
            + ';">'
            + html.escape(human_label(k))
            + "</td>"
            + '<td style="padding:12px 14px;font-size:14px;color:'
            + NAVY
            + ";font-weight:700;border-bottom:1px solid "
            + BORDER
            + ";word-break:break-word;overflow-wrap:anywhere;font-family:"
            + FONT
            + ';">'
            + html.escape(v)
            + "</td></tr>"
        )
    rows = "".join(row_html)
    if not rows:
        rows = (
            '<tr><td style="padding:14px;color:'
            + GRAY500
            + ';font-size:14px;">No details provided.</td></tr>'
        )

    actions_html = ""
    if not ok:
        items = "".join(
            '<li style="margin:0 0 8px;font-size:14px;line-height:1.55;color:'
            + GRAY900
            + ";font-family:"
            + FONT
            + ';">'
            + html.escape(a)
            + "</li>"
            for a in failure_actions()
        )
        actions_html = (
            '<h2 style="margin:24px 0 10px;font-size:15px;color:'
            + NAVY
            + ";font-weight:700;font-family:"
            + FONT_DISPLAY
            + ';">Recommended actions</h2>'
            '<ul style="margin:0 0 8px;padding-left:18px;">'
            + items
            + "</ul>"
        )

    year = time.gmtime().tm_year
    return (
        '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1.0">'
        '<meta name="color-scheme" content="light only">'
        '<meta name="supported-color-schemes" content="light">'
        "<title>StayLedger database backup</title>"
        "<!--[if mso]><style>body,table,td{font-family:Arial,Helvetica,sans-serif!important;}</style><![endif]-->"
        "</head>"
        '<body style="margin:0;padding:0;background:'
        + GRAY50
        + ";font-family:"
        + FONT
        + ";color:"
        + NAVY
        + ';">'
        '<div style="display:none;font-size:1px;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden;mso-hide:all;">'
        + html.escape(badge_text + ". " + summary)
        + "</div>"
        '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:'
        + GRAY50
        + ';padding:24px 12px;">'
        '<tr><td align="center">'
        '<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:'
        + WHITE
        + ";border-radius:14px;overflow:hidden;border:1px solid "
        + BORDER
        + ';">'
        '<tr><td style="background:'
        + NAVY
        + ';padding:0;">'
        '<div style="height:4px;background:'
        + accent
        + ';line-height:4px;font-size:0;">&nbsp;</div>'
        '<div style="padding:22px 24px 24px;">'
        '<div style="font-family:'
        + FONT_DISPLAY
        + ";font-size:12px;letter-spacing:0.12em;text-transform:uppercase;color:"
        + CYAN
        + ';font-weight:700;" role="img" aria-label="StayLedger">StayLedger</div>'
        '<div style="font-family:'
        + FONT_DISPLAY
        + ";font-size:11px;letter-spacing:0.06em;text-transform:uppercase;color:"
        + CYAN
        + ';font-weight:600;margin-top:10px;">Production infrastructure</div>'
        '<h1 style="margin:8px 0 0;font-family:'
        + FONT_DISPLAY
        + ";font-size:22px;line-height:1.3;color:"
        + WHITE
        + ';font-weight:700;">Database backup</h1>'
        '<p style="margin:14px 0 0;"><span style="display:inline-block;background:'
        + badge_bg
        + ";color:"
        + badge_fg
        + ";border:1px solid "
        + accent
        + ';font-size:12px;font-weight:700;letter-spacing:0.04em;padding:6px 12px;border-radius:999px;">'
        + ("✓ " if ok else "! ")
        + badge_text
        + "</span></p></div></td></tr>"
        '<tr><td style="padding:28px 24px;background:'
        + WHITE
        + ';">'
        '<p style="margin:0 0 8px;font-size:15px;line-height:1.55;color:'
        + GRAY900
        + ";font-family:"
        + FONT
        + ';">'
        + html.escape(summary)
        + "</p>"
        '<p style="margin:0 0 18px;font-size:13px;color:'
        + GRAY500
        + ";font-family:"
        + FONT
        + ';">'
        + html.escape(headline)
        + "</p>"
        '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;border:1px solid '
        + BORDER
        + ';border-radius:10px;overflow:hidden;">'
        + rows
        + "</table>"
        + actions_html
        + "</td></tr>"
        '<tr><td style="padding:18px 24px 24px;background:'
        + WHITE
        + ";border-top:1px solid "
        + BORDER
        + ';">'
        '<p style="margin:0;font-size:12px;line-height:1.55;color:'
        + GRAY500
        + ";font-family:"
        + FONT
        + ';">Automated operational notification for StayLedger Postgres backups (local PVC and S3 off-node). Times are UTC unless noted.</p>'
        '<p style="margin:14px 0 0;font-size:12px;color:'
        + NAVY
        + ';text-align:center;opacity:0.45;">© '
        + str(year)
        + " StayLedger</p>"
        "</td></tr></table></td></tr></table></body></html>"
    )


def build_text(ok: bool, headline: str, fields: list[tuple[str, str]]) -> str:
    enriched = enrich_fields(fields)
    backup_type = resolve_backup_type(enriched, headline)
    lines = [
        "StayLedger",
        "Database backup",
        "Status: " + ("succeeded" if ok else "FAILED — action required"),
        "",
        build_summary(ok, backup_type),
        headline,
        "",
    ]
    for key, value in enriched:
        lines.append(human_label(key) + ": " + value)
    if not ok:
        lines.append("")
        lines.append("Recommended actions:")
        for action in failure_actions():
            lines.append("- " + action)
    lines.append("")
    lines.append("Automated operational notification for StayLedger Postgres backups. Times are UTC.")
    return "\n".join(lines)


def main() -> int:
    wait_done()
    status = STATUS.read_text(encoding="utf-8").strip() if STATUS.exists() else "1"
    subject_tail = (
        SUBJECT_FILE.read_text(encoding="utf-8").strip()
        if SUBJECT_FILE.exists()
        else "StayLedger backup"
    )
    body = BODY_FILE.read_text(encoding="utf-8") if BODY_FILE.exists() else "status=" + status + "\n"
    ok = status == "0"

    to_addr = os.environ.get("BACKUP_NOTIFY_TO", "platform@stayledger.io").strip()
    from_addr = os.environ.get("EMAIL_FROM", "noreply@stayledger.io").strip()
    host = os.environ.get("SMTP_HOST", "email-smtp.ap-southeast-1.amazonaws.com").strip()
    port = int(os.environ.get("SMTP_PORT", "465"))
    user = os.environ.get("SMTP_USER", "").strip()
    password = os.environ.get("SMTP_PASS", "").strip()

    if not to_addr or not user or not password:
        print("[notify] ERROR: missing BACKUP_NOTIFY_TO / SMTP_USER / SMTP_PASS", flush=True)
        return 0 if ok else 1

    headline = redact(
        next(
            (ln.strip() for ln in body.splitlines() if ln.strip().startswith("StayLedger ")),
            subject_tail,
        )
    )
    fields = parse_fields(body)

    msg = EmailMessage()
    msg["Subject"] = build_subject(ok, subject_tail)
    msg["From"] = from_addr
    msg["To"] = to_addr
    msg.set_content(build_text(ok, headline, fields))
    msg.add_alternative(build_html(ok, headline, fields), subtype="html")

    try:
        ctx = ssl.create_default_context()
        with smtplib.SMTP_SSL(host, port, context=ctx, timeout=60) as smtp:
            smtp.login(user, password)
            smtp.send_message(msg)
        print(
            "[notify] emailed "
            + to_addr
            + " ("
            + ("SUCCESS" if ok else "FAILURE")
            + ")",
            flush=True,
        )
    except Exception as exc:  # noqa: BLE001
        print("[notify] ERROR send failed: " + type(exc).__name__ + ": " + str(exc), flush=True)

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
