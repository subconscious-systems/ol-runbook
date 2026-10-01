"""Validate profile resources and local/remote weight-script wiring offline."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
PROVIDERS = ('aws', 'gcp', 'azure', 'oci', 'coreweave', 'lambda', 'crusoe',
             'nebius', 'together', 'fireworks')


def download_args(script):
    result = subprocess.run([str(script)], capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


class ProviderProfileTests(unittest.TestCase):
    def test_every_profile_has_complete_consistent_local_settings(self):
        count = 0
        for provider in PROVIDERS:
            for base in sorted((ROOT / 'profiles').glob('*/values.yaml')):
                profile = base.parent.name
                folder = ROOT / provider / profile
                with self.subTest(provider=provider, profile=profile):
                    for name in ('deploy.sh', 'weights.sh', 'values.yaml', '.env.example', 'README.md'):
                        self.assertTrue((folder / name).is_file(), str(folder / name))
                    wrapper = shlex.split((folder / 'deploy.sh').read_text().splitlines()[-1])
                    self.assertEqual(wrapper[0], provider)
                    self.assertEqual(wrapper[3], profile)
                    values = yaml.safe_load((folder / 'values.yaml').read_text())
                    worker = values['worker']
                    gpu_count = worker['gpu']['count']
                    replicas = sum(m.get('replicas', 1) for m in values['models'])
                    self.assertEqual(gpu_count * replicas, int(wrapper[2]))
                    args = shlex.split(worker['sglang']['extraArgs'])
                    tp_flag = '--tp' if '--tp' in args else '--tp-size'
                    self.assertEqual(int(args[args.index(tp_flag) + 1]), gpu_count)
                    weights = (folder / 'weights.sh').read_text()
                    self.assertIn(f'"{worker["modelPath"]}"', weights)
                    if '--speculative-draft-model-path' in args:
                        draft = args[args.index('--speculative-draft-model-path') + 1]
                        self.assertIn(f'"{draft}"', weights)
                    mount = worker['weights']['hostPath']
                    self.assertTrue(mount['readOnly'])
                    self.assertTrue(Path(worker['modelPath']).is_relative_to(mount['mountPath']))
                    # All original image repositories and tags must survive profile filling.
                    original = yaml.safe_load(base.read_text())
                    self.assertEqual(worker['image'], original['worker']['image'])
                    count += 1
        self.assertEqual(count, 290)

    def test_weights_dispatch_the_same_checkpoints_locally_and_after_staging(self):
        # A fake downloader captures argv rather than asking for tokens or downloading.
        # Identical scripts have identical paths/argv logic; execute each distinct
        # script once while the completeness test above checks every folder.
        tested_scripts = set()
        with tempfile.TemporaryDirectory(prefix='profile weights ') as temp:
            root = Path(temp)
            local_root = root / 'checkout'
            remote_root = root / 'remote-home'
            shared = local_root / 'profiles/_weights.sh'
            shared.parent.mkdir(parents=True)
            remote_root.mkdir()
            shared.write_text('#!/usr/bin/env python3\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n')
            shared.chmod(0o755)
            shutil.copy2(shared, remote_root / '_weights.sh')
            for provider in PROVIDERS:
                for source in sorted((ROOT / provider).glob('*/weights.sh')):
                    content = source.read_bytes()
                    if content in tested_scripts:
                        continue
                    tested_scripts.add(content)
                    with self.subTest(provider=provider, profile=source.parent.name):
                        profile = source.parent.name
                        local = local_root / provider / profile / 'weights.sh'
                        local.parent.mkdir(parents=True, exist_ok=True)
                        remote = remote_root / profile / 'weights.sh'
                        remote.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(source, local)
                        shutil.copy2(source, remote)
                        local_args = download_args(local)
                        self.assertEqual(local_args, download_args(remote))
                        self.assertEqual(local_args[0], profile)
                        self.assertEqual(len(local_args) % 2, 1)
                        values = yaml.safe_load((source.parent / 'values.yaml').read_text())
                        self.assertIn(values['worker']['modelPath'], local_args[2::2])

    def test_named_l4_profiles_have_one_worker_and_legacy_examples_keep_four_gpus(self):
        for name, expected_gpus, expected_workers in (
            ('qwen3-8b-l4-1gpu', 1, 1), ('qwen36-27b-l4-2gpu', 2, 1),
            ('qwen3-8b', 4, 4), ('qwen36-27b', 4, 2),
        ):
            with self.subTest(profile=name):
                values = yaml.safe_load((ROOT / 'profiles' / name / 'values.yaml').read_text())
                workers = sum(m.get('replicas', 1) for m in values['models'])
                self.assertEqual(workers, expected_workers)
                self.assertEqual(workers * values['worker']['gpu']['count'], expected_gpus)

    def test_corrected_instance_mappings_and_removed_invalid_p4de_sizes(self):
        command = '''
die() { printf '%s\\n' "$*" >&2; exit 1; }
log() { :; }
source "$1"
resolve_instance_type "$2" "$3"
printf '%s' "$INSTANCE_TYPE"
'''
        cases = (
            ('aws', 'l4', '1', 'g6.4xlarge'),
            ('aws', 'l40s', '1', 'g6e.2xlarge'),
            ('aws', 'a100-80gb', '8', 'p4de.24xlarge'),
            ('gcp', 'b200', '8', 'a4-highgpu-8g'),
            ('azure', 'a100-80gb', '8', 'Standard_ND96amsr_A100_v4'),
            ('oci', 'a100-80gb', '8', 'BM.GPU.A100-v2.8'),
        )
        for provider, gpu, count, expected in cases:
            with self.subTest(provider=provider):
                result = subprocess.run(['bash', '-c', command, '_',
                                         str(ROOT / 'profiles/_providers' / f'{provider}.sh'), gpu, count],
                                        env={'PATH': os.environ['PATH']}, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)
        for count in ('1', '2'):
            result = subprocess.run(['bash', '-c', command, '_',
                                     str(ROOT / 'profiles/_providers/aws.sh'), 'a100-80gb', count],
                                    env={'PATH': os.environ['PATH']}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('set AWS_INSTANCE_TYPE', result.stderr)


if __name__ == '__main__':
    unittest.main()
