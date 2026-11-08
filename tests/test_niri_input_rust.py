"""Compatibility checks for the pure niri input transformations."""
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile
import unittest
from MacShell.niri_tools import input_config, without_input_preferences

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get("MACSHELL_TEST_NIRI_INPUT_HARNESS")
PROTOCOL_BINARY = os.environ.get("MACSHELL_TEST_NIRI_INPUT_BINARY")


@unittest.skipUnless(BINARY, "set MACSHELL_TEST_NIRI_INPUT_HARNESS")
class InputCompatibilityTests(unittest.TestCase):
    def call(self, requests):
        result = subprocess.run([BINARY], input="".join(json.dumps(x) + "\n" for x in requests),
                                text=True, capture_output=True, check=True, timeout=10)
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_generated_configs_match_python_and_niri_accepts_them(self):
        rng = random.Random(583)
        values = [dict(repeatRate=rng.uniform(-100, 300), repeatDelay=rng.uniform(0, 3000),
                       mouseSens=rng.uniform(-2, 2), tpScroll=rng.uniform(-2, 7),
                       **{key: rng.choice([True, False]) for key in ("mouseNatural", "tpNatural", "tpTap", "tpDwt")})
                  for _ in range(200)]
        output = self.call([dict(action="config", values=v) for v in values])
        self.assertEqual([x["value"] for x in output], [input_config(v) for v in values])
        with tempfile.TemporaryDirectory() as directory:
            import shutil
            if shutil.which("niri"):
                for index in (0, 1, 2):
                    path = Path(directory) / "input.kdl"
                    path.write_text(output[index]["value"])
                    subprocess.run(["niri", "validate", "-c", str(path)], check=True, capture_output=True, timeout=10)

    def test_realistic_profile_keeps_unrelated_configuration(self):
        inputs = [
            'input { keyboard { repeat-rate 30; xkb { layout "us,ru"; }; }; mouse { natural-scroll; accel-profile "flat"; }; }\n// repeat-rate 100\n',
            'input {\n touchpad { tap; dwt; scroll-factor 0.7; }\n keyboard { repeat-delay 400; }\n}\n',
            'input { mouse { accel-speed -0.2; } }\n// 日本語 { }\n',
        ]
        output = self.call([dict(action="strip", text=text) for text in inputs])
        self.assertEqual([x["value"] for x in output], [without_input_preferences(text) for text in inputs])

    def test_python_fragments_are_recognized_and_custom_edits_rejected(self):
        rng = random.Random(857)
        values = [dict(repeatRate=rng.uniform(-100, 300), repeatDelay=rng.uniform(0, 3000),
                       mouseSens=rng.uniform(-2, 2), tpScroll=rng.uniform(-2, 7),
                       **{key: rng.choice([True, False]) for key in ("mouseNatural", "tpNatural", "tpTap", "tpDwt")})
                  for _ in range(200)]
        desired = values[0]
        fragments = [input_config(value) for value in values]
        results = self.call([dict(action="plan", text=text, values=desired) for text in fragments])
        self.assertEqual(results, [{"value": "accepted"}] * len(fragments))
        result = self.call([dict(action="plan", text=fragments[0] + "// custom\n", values=desired)])[0]
        self.assertIn("unrecognized changes", result["error"])

    @unittest.skipUnless(PROTOCOL_BINARY, "set MACSHELL_TEST_NIRI_INPUT_BINARY")
    def test_binary_protocol_version(self):
        result = subprocess.run([PROTOCOL_BINARY, "--protocol-version"], capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.strip(), "macshell-niri-input 1")

    @unittest.skipUnless(PROTOCOL_BINARY and shutil.which("niri"), "Rust input binary and niri are required")
    def test_end_to_end_temp_profile_and_pending_block(self):
        values = {"repeatRate": 30, "repeatDelay": 500, "mouseSens": 0,
                  "tpScroll": 0.7, "mouseNatural": False, "tpNatural": True,
                  "tpTap": True, "tpDwt": True}
        with tempfile.TemporaryDirectory(prefix="macshell-input-e2e-") as directory:
            profile = Path(directory)
            (profile / "config.kdl").write_text('include "./macshell-input.kdl"\n')
            initial = "// Input preferences remain unchanged until edited in MacShell.\n"
            fragment = profile / "macshell-input.kdl"
            fragment.write_text(initial)
            env = dict(os.environ, MACSHELL_NIRI_PROFILE=str(profile),
                       MACSHELL_INPUT_FRAGMENT=str(fragment))
            first = subprocess.run([PROTOCOL_BINARY, "input", json.dumps(values)], env=env,
                                   capture_output=True, text=True, timeout=20)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertNotEqual(fragment.read_text(), initial)
            journals = list(profile.glob(".macshell-input-journal-*"))
            candidates = list(profile.glob(".macshell-input-[0-9a-f][0-9a-f]*"))
            self.assertTrue(journals)
            self.assertTrue(candidates)
            second = subprocess.run([PROTOCOL_BINARY, "input", json.dumps(values)], env=env,
                                    capture_output=True, text=True, timeout=20)
            self.assertNotEqual(second.returncode, 0)
            self.assertIn("unfinished input transaction", second.stderr)

    @unittest.skipUnless(PROTOCOL_BINARY, "set MACSHELL_TEST_NIRI_INPUT_BINARY")
    def test_service_launcher_prefers_rust_and_falls_back_before_transaction(self):
        service_source = ROOT / "MacShell" / "niri-input-service.sh"
        with tempfile.TemporaryDirectory(prefix="macshell-input-launcher-") as directory:
            root = Path(directory)
            service = root / "niri-input-service.sh"
            service.write_text(service_source.read_text())
            service.chmod(0o755)
            binary = root / "niri-input-rust"
            shutil.copy2(PROTOCOL_BINARY, binary)
            binary.chmod(0o755)
            (root / "niri_tools.py").write_text("import sys; print('python-fallback:' + sys.argv[1])\n")
            rust = subprocess.run([str(service), "--protocol-version"], capture_output=True, text=True, check=True)
            self.assertEqual(rust.stdout.strip(), "macshell-niri-input 1")
            binary.unlink()
            fallback = subprocess.run([str(service), "input", "{}"], capture_output=True, text=True, check=True)
            self.assertEqual(fallback.stdout.strip(), "python-fallback:input")


if __name__ == "__main__":
    unittest.main()
