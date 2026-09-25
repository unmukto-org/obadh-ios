#!/usr/bin/env python3
"""Analyze an explicit, local pilot export. Raw sessions are never copied to Git.

Usage: scripts/analyze-accuracy-pilot.py session.json [output-directory]
Requires the repository's Swift toolchain; plots additionally use matplotlib.
"""
import collections
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def percentile95(values):
    return sorted(values)[math.ceil(len(values) * .95) - 1]


def analyze(source, output):
    output.mkdir(parents=True, exist_ok=True)
    raw = source.read_bytes()
    session = json.loads(raw)
    report = json.loads(subprocess.check_output(
        ['swift', 'run', 'typing-accuracy-report', str(source)], cwd=ROOT))
    replay = json.loads(subprocess.check_output(
        [str(ROOT / 'scripts/replay-accuracy-session.sh'), str(source)], cwd=ROOT))
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    (output / 'replay.json').write_text(json.dumps(replay, indent=2) + '\n')
    if report['coverage']['duplicateTrialIDs'] or report['coverage']['unexpectedTrialIDs']:
        raise ValueError('Trial IDs do not match the study plan; aggregate comparison rejected.')
    if any(not t['prompt'].isascii() or not t['entered'].isascii() for t in session['trials']):
        raise ValueError('This replay audit is for the ASCII Roman motor task; use the Swift scorer for Unicode text.')
    scores = {t['id']: t for t in report['trials']}
    replays = {t['id']: t for t in replay}
    trials = []
    for trial in session['trials']:
        resolved = replays[trial['id']]
        contacts = resolved['resolutions']
        comparable = resolved['recordedLiftOffKeysMatchCommits'] is True
        delays = [(c['time'] - contact['upTime']) * 1000
                  for c, contact in zip(trial['commits'], contacts)] if comparable else []
        gaps = [(b['downTime'] - a['upTime']) * 1000 for a, b in zip(contacts, contacts[1:])]
        holds = [(c['upTime'] - c['downTime']) * 1000 for c in contacts]
        # Independently reconstruct the lab's text mutations, including shift.
        text, shifted, backspaces = '', False, 0
        for commit in trial['commits']:
            key = commit['key']
            if key.startswith('character:'):
                value = key[len('character:'):]
                text += value.upper() if shifted else value
                shifted = False
            elif key == 'space':
                text += ' '
            elif key == 'backspace':
                text = text[:-1]
                backspaces += 1
            elif key == 'shift':
                shifted = not shifted
        trials.append(dict(
            id=trial['id'], posture=trial['posture'], variant=trial['variant'],
            durationSeconds=trial['endedAt'] - trial['startedAt'], score=scores[trial['id']]['score'],
            backspaces=trial['backspaces'], deliveredContacts=len(contacts),
            overlaps=sum(c['overlapsEarlierContact'] for c in contacts),
            malformedContacts=resolved['malformedContacts'], spatialReplayMatches=comparable,
            textReplayMatches=text == trial['entered'],
            actionCountMatches=trial['actions'] == len(trial['commits']),
            backspaceCountMatches=backspaces == trial['backspaces'],
            holdMedianMs=statistics.median(holds) if holds else None,
            gapMedianMs=statistics.median(gaps) if gaps else None,
            releaseToCommitMs=delays,
            latencyMedianMs=statistics.median(delays) if delays else None,
            latencyP95Ms=percentile95(delays) if delays else None,
        ))
    groups = []
    for posture in sorted({t['posture'] for t in trials}):
        for variant in ['baseline-112', 'ordered-rollover']:
            subset = [t for t in trials if t['posture'] == posture and t['variant'] == variant and t['score'] is not None]
            if not subset:
                continue
            reference = sum(t['score']['referenceUnits'] for t in subset)
            entered = sum(t['score']['enteredUnits'] for t in subset)
            seconds = sum(t['durationSeconds'] for t in subset)
            edits = sum(t['score']['edits'] for t in subset)
            latency = [ms for t in subset for ms in t['releaseToCommitMs']]
            groups.append(dict(posture=posture, variant=variant, trials=len(subset), referenceUnits=reference,
                               durationSeconds=seconds, finalEdits=edits, cer=edits/reference,
                               graphemesPerMinute=entered * 60 / seconds,
                               backspaces=sum(t['backspaces'] for t in subset),
                               latencyMedianMs=statistics.median(latency) if latency else None,
                               latencyP95Ms=percentile95(latency) if latency else None))
    result = dict(sessionID=session['sessionID'], sourceSHA256=hashlib.sha256(raw).hexdigest(),
                  sourceRevision=session['sourceRevision'], provenance=session['provenance'],
                  coverage=report['coverage'], framesIdentical=all(t['frames'] == session['trials'][0]['frames'] for t in session['trials']),
                  groups=groups, trials=trials,
                  limitations=['One-person prompted pilot; no causal or population claim.',
                               'Baseline may suppress contacts before logging.',
                               'Release-to-commit timing excludes visible presentation latency.',
                               'Prompt mismatches do not establish intended finger targets.'])
    (output / 'audit.json').write_text(json.dumps(result, indent=2) + '\n')
    try:
        plot(result, output)
    except ImportError:
        print('matplotlib unavailable; JSON analysis complete, plot omitted.', file=sys.stderr)
    print(json.dumps({k: result[k] for k in ['coverage', 'framesIdentical', 'groups']}, indent=2))


def plot(result, output):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    variants = ['baseline-112', 'ordered-rollover']
    colors = ['#496b94', '#c46635']
    fig, axes = plt.subplots(1, 3, figsize=(12, 4.1), layout='constrained')
    for panel, (key, title, ylabel) in enumerate([
        ('graphemesPerMinute', 'Typing rate', 'Roman characters / minute'),
        ('finalEdits', 'Uncorrected errors', 'Edit operations / 64 reference characters'),
        ('latencyMedianMs', 'Input handling', 'Median release-to-commit time (ms)'),
    ]):
        ax = axes[panel]
        for v, (variant, color) in enumerate(zip(variants, colors)):
            group = [next((g for g in result['groups'] if g['posture'] == p and g['variant'] == variant), None)
                     for p in ['one-thumb', 'two-thumbs']]
            values = [g[key] if g else float('nan') for g in group]
            bars = ax.bar([i + (v-.5)*.32 for i in range(2)], values, .3,
                          color=color, label='Release 112 routing' if v == 0 else 'Ordered rollover')
            ax.bar_label(bars, fmt='%.1f' if panel != 1 else '%d', padding=3)
        ax.set_xticks([0, 1], ['One thumb', 'Two thumbs'])
        ax.set_title(title)
        ax.set_ylabel(ylabel)
        ax.set_ylim(0, ax.get_ylim()[1]*1.15)
        ax.spines[['top', 'right']].set_visible(False)
    axes[0].set_ylim(0, max(g['graphemesPerMinute'] for g in result['groups']) * 1.4)
    axes[0].legend(loc='upper right', fontsize=8)
    fig.suptitle('First phone pilot: no demonstrated accuracy gain', fontsize=15)
    fig.supxlabel('One participant, two repeated phrases per condition. No recorded overlap; order and practice effects remain.', fontsize=9)
    fig.savefig(output / 'pilot-summary.png', dpi=170)
    fig.savefig(output / 'pilot-summary.svg')
    plt.close(fig)


if __name__ == '__main__':
    if len(sys.argv) not in (2, 3):
        raise SystemExit(__doc__)
    analyze(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve() if len(sys.argv) == 3 else ROOT / 'build/TypingAccuracyPilot')
