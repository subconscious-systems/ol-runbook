"""Check Modal profile wiring with local doubles; never provision resources."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[1] / "modal"
PROFILES = sorted(path.parent for path in ROOT.glob("*/deploy.py"))


def decorate(**options):
    def wrapper(function):
        function.options = {**getattr(function, "options", {}), **options}
        function.remote = Mock()
        return function
    return wrapper


def sdk_double():
    image = Mock()
    image.env.return_value = image
    image.pip_install.return_value = image
    return SimpleNamespace(
        is_local=lambda: True,
        Image=SimpleNamespace(from_registry=Mock(return_value=image),
                              debian_slim=Mock(return_value=image)),
        Secret=SimpleNamespace(from_name=lambda name, **kwargs: name),
        Volume=SimpleNamespace(from_name=lambda name, **kwargs: Mock(name=name)),
        App=lambda name: SimpleNamespace(function=decorate, local_entrypoint=decorate),
        concurrent=decorate,
        web_server=decorate,
    )


def load(path):
    spec = importlib.util.spec_from_file_location("profile_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ModalTests(unittest.TestCase):
    def setUp(self):
        self.sdk = sdk_double()
        self.modules = patch.dict(sys.modules, {"modal": self.sdk})
        self.modules.start()
        self.addCleanup(self.modules.stop)
        self.env = patch.dict(os.environ, {
            "ORANGELINE_IMAGE_NAME": "example/runtime:test",
            "HF_TOKEN_SECRET": "test-hf",
            "DOCKER_TOKEN_SECRET": "test-registry",
        })
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_downloads_match_serving_mounts_and_checkpoint_arguments(self):
        self.assertEqual(len(PROFILES), 3)
        for profile in PROFILES:
            with self.subTest(profile=profile.name):
                deploy = load(profile / "deploy.py")
                weights = load(profile / "download_weights.py")
                self.assertEqual(deploy.WEIGHTS_VOLUME, weights.WEIGHTS_VOLUME)
                self.assertEqual(deploy.WEIGHTS_MOUNT, weights.WEIGHTS_MOUNT)
                self.assertEqual(deploy.HF_SECRET, "test-hf")
                self.assertEqual(weights.HF_SECRET, deploy.HF_SECRET)
                cmd = deploy.server_command()
                paths = [cmd[cmd.index(flag) + 1] for flag in
                         ("--model-path", "--speculative-draft-model-path")]
                self.assertEqual(paths, [spec["local_dir"] for spec in weights.MODELS])
                expected_repo = ("nvidia/GLM-5.2-NVFP4" if "nvfp4" in profile.name
                                 else "zai-org/GLM-5.2-FP8")
                self.assertEqual(weights.MODELS[0]["repo_id"], expected_repo)
                for path in paths:
                    self.assertTrue(Path(path).is_relative_to(weights.WEIGHTS_MOUNT))
                self.assertEqual(cmd[cmd.index("--served-model-name") + 1], "glm-5.2")
                snapshot = Mock()
                with patch.dict(sys.modules, {"huggingface_hub": SimpleNamespace(snapshot_download=snapshot)}):
                    with contextlib.redirect_stdout(io.StringIO()):
                        weights.download()
                self.assertEqual(snapshot.call_count, 2)
                self.assertEqual(weights.vol.commit.call_count, 2)
                for call, spec in zip(snapshot.call_args_list, weights.MODELS):
                    self.assertEqual(call.kwargs["repo_id"], spec["repo_id"])
                    self.assertEqual(call.kwargs["local_dir"], spec["local_dir"])
                weights.main()
                weights.download.remote.assert_called_once_with()

    def test_gpu_resources_concurrency_and_spawn_match_profile(self):
        apps, caches = set(), set()
        for profile in PROFILES:
            with self.subTest(profile=profile.name):
                deploy = load(profile / "deploy.py")
                count = 8 if "8gpu" in profile.name else 4
                options = deploy.serve.options
                self.assertEqual(options["gpu"], f"B200:{count}")
                self.assertEqual(options["cpu"], count * 8)
                cmd = deploy.server_command()
                self.assertEqual(cmd[cmd.index("--tp") + 1], str(count))
                self.assertEqual(int(cmd[cmd.index("--max-running-requests") + 1]),
                                 options["max_inputs"])
                self.assertEqual(options["label"], deploy.APP_NAME)
                self.assertIn(deploy.CACHE_MOUNT, options["volumes"])
                apps.add(deploy.APP_NAME)
                caches.add(deploy.CACHE_VOLUME)
                with patch.object(deploy.subprocess, "Popen") as spawn:
                    with contextlib.redirect_stdout(io.StringIO()):
                        deploy.serve()
                self.assertEqual(spawn.call_args.args, (cmd,))
        self.assertEqual(len(apps), len(PROFILES))
        self.assertEqual(len(caches), len(PROFILES))

    def test_profile_env_selects_secrets_for_deploy_and_downloader(self):
        with tempfile.TemporaryDirectory() as temp:
            dotenv = Path(temp) / ".env"
            dotenv.write_text('HF_TOKEN_SECRET="profile-hf"\nDOCKER_TOKEN_SECRET=profile-registry\n')
            for profile in PROFILES:
                with self.subTest(profile=profile.name), patch.dict(os.environ, {}, clear=True):
                    # Redirect only .env reads, without copying local credential files.
                    with patch.object(Path, "exists", return_value=True), patch.object(Path, "read_text", return_value=dotenv.read_text()):
                        with patch.dict(os.environ, {"ORANGELINE_IMAGE_NAME": "example/runtime:test"}):
                            deploy = load(profile / "deploy.py")
                            weights = load(profile / "download_weights.py")
                    self.assertEqual(deploy.HF_SECRET, "profile-hf")
                    self.assertEqual(weights.HF_SECRET, deploy.HF_SECRET)
                    self.assertEqual(deploy.DOCKER_TOKEN_SECRET, "profile-registry")

    def test_secret_files_are_private_removed_and_not_in_cli_arguments(self):
        for profile in PROFILES:
            helper = load(profile / "scripts/write_secrets.py")
            for code in (0, 9):
                with self.subTest(profile=profile.name, code=code):
                    paths = []
                    def run(argv, **kwargs):
                        path = Path(argv[argv.index("--from-json") + 1])
                        paths.append(path)
                        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                        self.assertEqual(json.loads(path.read_text()), {"HF_TOKEN": "test-secret-value"})
                        self.assertNotIn("test-secret-value", " ".join(argv))
                        return SimpleNamespace(returncode=code)
                    output = io.StringIO()
                    with patch.object(helper.subprocess, "run", side_effect=run):
                        with contextlib.redirect_stdout(output):
                            if code:
                                with self.assertRaises(SystemExit):
                                    helper.upsert_secret("test-hf", {"HF_TOKEN": "test-secret-value"})
                            else:
                                helper.upsert_secret("test-hf", {"HF_TOKEN": "test-secret-value"})
                    self.assertNotIn("test-secret-value", output.getvalue())
                    self.assertEqual(len(paths), 1)
                    self.assertFalse(paths[0].exists())

    def test_secret_helper_uses_configured_names_and_requires_credentials(self):
        for profile in PROFILES:
            with self.subTest(profile=profile.name):
                helper = load(profile / "scripts/write_secrets.py")
                env = dict(HF_TOKEN="hf-value", REGISTRY_USERNAME="user", REGISTRY_PASSWORD="password",
                           HF_TOKEN_SECRET="profile-hf", DOCKER_TOKEN_SECRET="profile-registry")
                with patch.object(helper, "load_dotenv", return_value=env):
                    with patch.object(helper, "upsert_secret") as upsert:
                        with contextlib.redirect_stdout(io.StringIO()):
                            helper.main()
                        self.assertEqual([call.args[0] for call in upsert.call_args_list],
                                         ["profile-hf", "profile-registry"])
                        env["REGISTRY_PASSWORD"] = ""
                        upsert.reset_mock()
                        with self.assertRaisesRegex(SystemExit, "REGISTRY_PASSWORD"):
                            helper.main()
                        upsert.assert_not_called()


if __name__ == "__main__":
    unittest.main()
