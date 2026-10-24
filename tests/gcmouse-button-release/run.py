"""Exercise real GCMouse callbacks and capture cleanup with controlled queues."""
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parents[2]
subprocess.run([sys.executable, str(root / 'tests/mouse-aux-buttons/run.py'),
                '--require-ownership', '--release-regressions', *sys.argv[1:]], check=True)
