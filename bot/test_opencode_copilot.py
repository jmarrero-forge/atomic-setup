"""Tests of opencode-copilot's login formats and its refusal of an existing database."""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "opencode-copilot")
_loader = importlib.machinery.SourceFileLoader("opencode_copilot", SCRIPT)
oc = importlib.util.module_from_spec(importlib.util.spec_from_loader("opencode_copilot", _loader))
_loader.exec_module(oc)


class LoginTest(unittest.TestCase):
    def test_logins_go_both_ways(self):
        cases = [
            # name, opencode 1's auth.json entry, the credential's metadata
            ("github.com", {"type": "oauth", "refresh": "gho_a", "access": "gho_a", "expires": 0}, None),
            ("Enterprise Cloud", {"type": "oauth", "refresh": "gho_b", "access": "gho_b", "expires": 0,
                                  "enterpriseUrl": "acme.ghe.com"}, {"enterpriseUrl": "acme.ghe.com"}),
            ("with its API endpoint", {"type": "oauth", "refresh": "gho_c", "access": "gho_c", "expires": 0,
                                       "apiEndpoint": "https://api.business.githubcopilot.com"},
             {"apiEndpoint": "https://api.business.githubcopilot.com"}),
        ]
        for name, login, metadata in cases:
            with self.subTest(name):
                [credential] = oc.credentials(json.dumps({"github-copilot": login, "other": {"type": "api"}}))
                self.assertEqual((credential["id"], credential["integrationID"], credential["active"]),
                                 ("cred_bot_copilot", "github-copilot", True))
                self.assertEqual(credential["value"].get("metadata"), metadata)
                self.assertEqual(credential["value"]["refresh"], login["refresh"])
                self.assertEqual(oc.login_from_export(json.dumps([credential])), {"github-copilot": login})

    def test_the_active_copilot_login_is_taken_from_an_export(self):
        def entry(token, active, integration="github-copilot"):
            return {"id": token, "integrationID": integration, "label": "OAuth", "active": active,
                    "value": {"type": "oauth", "methodID": "device", "refresh": token, "access": token, "expires": 0}}
        exported = [entry("old", False), entry("other", True, "openai"), entry("new", True)]
        self.assertEqual(oc.login_from_export(json.dumps(exported))["github-copilot"]["refresh"], "new")

    def test_bad_logins_are_refused(self):
        for content in ["", "not json", "{}", '{"github-copilot": {}}', "[]"]:
            with self.subTest(content), self.assertRaises(SystemExit):
                oc.credentials(content)
        for exported in ["{}", "[]", '[{"integrationID": "openai", "value": {"type": "oauth"}}]',
                         '[{"integrationID": "github-copilot", "value": {"type": "oauth"}}]']:
            with self.subTest(exported), self.assertRaises(SystemExit):
                oc.login_from_export(exported)

    def test_a_failed_import_doesnt_show_the_token(self):
        with tempfile.TemporaryDirectory() as d:
            # An opencode that fails, quoting what it was given.
            fake = os.path.join(d, "opencode")
            with open(fake, "w") as f:
                f.write("#!/bin/sh\ncat >&2\nexit 1\n")
            os.chmod(fake, 0o755)
            env = {"PATH": f"{d}:/usr/bin:/bin", "HOME": d, "XDG_DATA_HOME": d,
                   "OPENCODE_AUTH_CONTENT": json.dumps({"github-copilot": {"refresh": "gho_s3cret", "access": "tid_x"}})}
            p = subprocess.run([sys.executable, "-I", SCRIPT, "run", "x"], env=env, capture_output=True, text=True)
            self.assertEqual(p.returncode, 1)
            self.assertIn("importing the login failed", p.stderr)
            self.assertNotIn("gho_s3cret", p.stderr)
            self.assertNotIn("tid_x", p.stderr)
            self.assertIn("[token]", p.stderr)

    def test_an_existing_database_is_refused_before_opencode_runs(self):
        with tempfile.TemporaryDirectory() as d:
            data = os.path.join(d, "opencode")
            os.makedirs(data)
            open(os.path.join(data, "opencode.db"), "w").close()
            # No opencode on PATH: it must stop before needing one.
            env = {"PATH": "/nonexistent", "HOME": d, "XDG_DATA_HOME": d,
                   "OPENCODE_AUTH_CONTENT": json.dumps({"github-copilot": {"refresh": "gho_x"}})}
            for extra, db in [({}, os.path.join(data, "opencode.db")),
                              ({"OPENCODE_DB": os.path.join(d, "own.db")}, os.path.join(d, "own.db"))]:
                with self.subTest(db=db):
                    open(db, "a").close()
                    p = subprocess.run([sys.executable, "-I", SCRIPT, "run", "x"], env=dict(env, **extra),
                                       capture_output=True, text=True)
                    self.assertEqual(p.returncode, 1)
                    self.assertIn(f"{db} already exists", p.stderr)


if __name__ == "__main__":
    unittest.main()
