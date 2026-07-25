#!/usr/bin/env python3
"""Unit tests for backup-notify.py email helpers (no SMTP)."""
from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

NOTIFY_PATH = Path(__file__).resolve().parent / "backup-notify.py"


def load_notify():
    spec = importlib.util.spec_from_file_location("backup_notify", NOTIFY_PATH)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class BackupNotifyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.mod = load_notify()

    def test_subjects(self) -> None:
        self.assertIn("Database backup succeeded", self.mod.build_subject(True, "tail"))
        self.assertIn("ACTION REQUIRED", self.mod.build_subject(False, "tail"))
        doc_fields = [("service", "StayLedger Guest Documents")]
        self.assertIn(
            "Document backup succeeded",
            self.mod.build_subject(True, "document S3", "StayLedger Guest Documents S3", doc_fields),
        )

    def test_redaction(self) -> None:
        fields = self.mod.parse_fields(
            "object=s3://b/k?X-Amz-Signature=abc&password=secret\n"
            "started_at=2026-07-15T11:49:11Z\n"
            "finished_at=2026-07-15T11:49:14Z\n"
        )
        self.assertTrue(any("[REDACTED]" in v for _, v in fields))

    def test_duration_enrichment(self) -> None:
        fields = [
            ("started_at", "2026-07-15T11:49:11Z"),
            ("finished_at", "2026-07-15T11:49:14Z"),
        ]
        enriched = self.mod.enrich_fields(fields)
        self.assertTrue(any(k == "duration" and v == "3s" for k, v in enriched))
        self.assertTrue(any(k == "environment" for k, _ in enriched))

    def test_html_success_and_failure(self) -> None:
        ok_html = self.mod.build_html(
            True,
            "StayLedger Postgres S3 (off-node) backup SUCCEEDED",
            [
                ("started_at", "2026-07-15T11:49:11Z"),
                ("finished_at", "2026-07-15T11:49:14Z"),
                ("object", "s3://prd/stayledger/production/postgres/f.dump"),
                ("retention_days", "30"),
            ],
        )
        self.assertIn("#0B132B", ok_html)
        self.assertIn("Backup succeeded", ok_html)
        self.assertNotIn("Recommended actions", ok_html)

        fail_html = self.mod.build_html(
            False,
            "StayLedger Postgres local backup FAILED",
            [
                ("started_at", "2026-07-15T12:00:01Z"),
                ("finished_at", "2026-07-15T12:00:02Z"),
                ("exit_code", "1"),
            ],
        )
        self.assertIn("Recommended actions", fail_html)
        self.assertIn("action required", fail_html.lower())

    def test_text_and_summary(self) -> None:
        text = self.mod.build_text(
            False,
            "StayLedger Postgres local backup FAILED",
            [("exit_code", "1")],
        )
        self.assertIn("Recommended actions:", text)
        self.assertIn("failed", self.mod.build_summary(False, "Local PVC").lower())

    def test_sanitize_object_hides_full_key_and_query(self) -> None:
        san = self.mod.sanitize_object(
            "s3://prd-bucket/stayledger/production/postgres/f.dump?X-Amz-Signature=abc"
        )
        self.assertEqual(san, "s3://prd-bucket/.../f.dump")
        self.assertNotIn("X-Amz", san)
        self.assertNotIn("production/postgres", san)

    def test_stage_created_when_no_integrity_fields(self) -> None:
        enriched = self.mod.enrich_fields(
            [("object", "s3://b/k/f.dump")], "StayLedger Postgres S3 backup SUCCEEDED", True
        )
        by_key = {k: v for k, v in enriched}
        self.assertEqual(by_key.get("stage"), "Created")
        self.assertEqual(by_key.get("integrity"), "Not reported")

    def test_stage_verified_when_checksum_present(self) -> None:
        enriched = self.mod.enrich_fields(
            [("object", "s3://b/k/f.dump"), ("md5", "d41d8cd98f00b204e9800998ecf8427e")],
            "StayLedger Postgres S3 backup SUCCEEDED",
            True,
        )
        by_key = {k: v for k, v in enriched}
        self.assertIn("integrity verified", by_key.get("stage", "").lower())
        self.assertIn("md5", by_key.get("integrity", "").lower())

    def test_stage_restore_tested_when_restore_field_present(self) -> None:
        self.assertEqual(
            self.mod.resolve_stage([("restore_tested", "true")]),
            "Created, integrity verified, restore tested",
        )

    def test_failure_omits_stage_and_integrity(self) -> None:
        enriched = self.mod.enrich_fields(
            [("exit_code", "1")], "StayLedger Postgres local backup FAILED", False
        )
        keys = {k for k, _ in enriched}
        self.assertNotIn("stage", keys)
        self.assertNotIn("integrity", keys)

    def test_document_html(self) -> None:
        html = self.mod.build_html(
            True,
            "StayLedger Guest Documents S3 (off-node) backup SUCCEEDED",
            [
                ("service", "StayLedger Guest Documents"),
                ("started_at", "2026-07-16T08:30:09Z"),
                ("finished_at", "2026-07-16T08:30:14Z"),
                ("object", "s3://prd-stayledger-pms/production/guest-documents/x.tar.gz.enc"),
            ],
        )
        self.assertIn("Document backup", html)
        self.assertIn("Guest document production backup", html)
        self.assertIn("guest documents s3", html.lower())


if __name__ == "__main__":
    unittest.main()
