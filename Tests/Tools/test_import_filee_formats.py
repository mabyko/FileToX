import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "importer", Path(__file__).resolve().parents[2] / "Tools/import-filee-formats.py"
)
importer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(importer)


class ProvenanceTests(unittest.TestCase):
    def test_modified_source_and_replace_refs_cannot_impersonate_pinned_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def git(*args):
                return subprocess.run(
                    ["git", "-C", str(root), *args], check=True,
                    capture_output=True, text=True, encoding="utf-8"
                ).stdout.strip()

            git("init", "--quiet")
            source = root / importer.REGISTRY_REL
            model = root / importer.MODEL_REL
            source.parent.mkdir(parents=True)
            source.write_text("original → PNG\n", encoding="utf-8")
            model.write_text("original model\n", encoding="utf-8")
            git("add", ".")
            git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture")
            commit = git("rev-parse", "HEAD")
            with patch.object(importer, "PINNED_COMMIT", commit):
                self.assertEqual(importer.load_sources(source), ("original → PNG\n", "original model\n"))
                original = git("rev-parse", commit + ":" + importer.REGISTRY_REL)
                source.write_text("forged → PNGX\n", encoding="utf-8")
                with self.assertRaises(importer.ImportError_):
                    importer.load_sources(source)
                replacement = git("hash-object", "-w", "--no-filters", str(source))
                git("replace", original, replacement)
                self.assertEqual(git("show", commit + ":" + importer.REGISTRY_REL), "forged → PNGX")
                with self.assertRaises(importer.ImportError_):
                    importer.load_sources(source)


if __name__ == "__main__":
    unittest.main()
