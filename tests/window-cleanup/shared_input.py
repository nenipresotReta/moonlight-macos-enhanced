"""Run the shared production GCMouse fixture, including cross-stream ownership.

The auxiliary-button suite now exercises the real ordered button dispatcher and
capture/context setters as well as the registration and teardown methods. Reuse
it so the ownership regression cannot silently rely on a stubbed sender.
"""
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parents[2]
subprocess.run([sys.executable, str(root / 'tests/mouse-aux-buttons/run.py'),
                '--require-ownership'], check=True)
