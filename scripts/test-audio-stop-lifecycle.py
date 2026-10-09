#!/usr/bin/env python3
"""Compile the engine's actual lifecycle methods with inert deterministic dependencies.
No app, microphone, private recordings, encoding or network is used. An optional
--source permits red/green comparison against a saved revision of the engine.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, default=root / 'recall/Core/Audio/AudioRecordingEngine.swift')
args = parser.parse_args()
source = args.source.read_text()
methods = ['stop', 'retireProcessingGeneration', 'canProcess', 'startProcessingLoop',
           'processCurrentAudio', 'handleVoiceDetected', 'handleSilence', 'startNewChunk',
           'writeCurrentAudioToChunk', 'drainCurrentAudioToChunk', 'finalizeCurrentChunk',
           'forceFinalizePendingBuffer', 'cleanupCurrentChunkState', 'splitChunk',
           'handleInterruptionBegan']
extracted = []
for name in methods:
    marker = f'func {name}('
    if marker not in source:
        continue  # Older revisions do not have generation/drain helpers.
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    extracted.append(source[start:end])
fixture = (root / 'Tests/AudioStopLifecycleFixture.swift').read_text()
fixture = fixture.replace('// ENGINE_METHODS', '\n\n'.join(extracted))
with tempfile.TemporaryDirectory(prefix='recall-stop-') as directory:
    directory = Path(directory)
    swift = directory / 'fixture.swift'
    swift.write_text(fixture)
    binary = directory / 'fixture'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(directory / 'cache'),
                    str(root / 'recall/Core/Audio/RingBuffer.swift'), str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)

# Run the existing ring snapshot/cursor tests unchanged, with a local XCTest entry point.
ring_tests = (root / 'Tests/recallTests/RingBufferStreamTests.swift').read_text()
ring_tests = ring_tests.replace('@testable import recall', 'import Foundation')
ring_tests += '\nlet suite = XCTestSuite(forTestCaseClass: RingBufferStreamTests.self)\nsuite.run()\nlet result = suite.testRun!\nprint("ring tests=\\(result.executionCount), failures=\\(result.totalFailureCount)")\nassert(result.executionCount == 6 && result.totalFailureCount == 0)\n'
with tempfile.TemporaryDirectory(prefix='recall-ring-') as directory:
    directory = Path(directory)
    swift = directory / 'main.swift'
    swift.write_text(ring_tests)
    binary = directory / 'tests'
    developer = subprocess.check_output(['xcode-select', '-p'], text=True).strip()
    frameworks = Path(developer) / 'Platforms/MacOSX.platform/Developer/Library/Frameworks'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(directory / 'cache'),
                    '-F', str(frameworks), '-I', str(frameworks.parent.parent / 'usr/lib'),
                    '-L', str(frameworks.parent.parent / 'usr/lib'), '-lXCTestSwiftSupport',
                    '-Xlinker', '-rpath', '-Xlinker', str(frameworks),
                    '-Xlinker', '-rpath', '-Xlinker', str(frameworks.parent.parent / 'usr/lib'),
                    str(root / 'recall/Core/Audio/RingBuffer.swift'), str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
