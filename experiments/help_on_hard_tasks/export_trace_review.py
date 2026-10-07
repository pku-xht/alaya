"""Export selected public tool feedback and questions, never model reasoning."""
import argparse
import json
from pathlib import Path
import subprocess

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--run-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    state = json.loads((args.run_root/'state.json').read_text())
    if not state.get('grade'):
        raise RuntimeError('review export requires completed terminal grading')
    raw = subprocess.check_output([str(args.binary), 'log', state['entry'], '--data',
                                   str(args.run_root/'data'), '--json'])
    rows = [json.loads(line) for line in raw.splitlines() if line.strip()]
    clock, time_checks, time_tool_returns, errors, questions = 0, [], [], [], []
    for row in rows:
        clock += row.get('elapsed_ms',0)
        event=row.get('event',{})
        op=event.get('op',{}).get('type')
        if op == 'time' and event.get('answer') is not None:
            time_checks.append({'entry':row['entry'],'seconds':round(clock/1000,3),
                                'recorded_timing':event['answer']})
        if event.get('type') == 'returned' and event.get('frame', [''])[-1].split('#')[0] == 'time_budget':
            time_tool_returns.append({'entry':row['entry'],'seconds':round(clock/1000,3),
                                      'tool_value':event.get('value')})
        if event.get('type') == 'asked':
            questions.append({'entry':row['entry'],'seconds':round(clock/1000,3),
                              'question':event['question']})
        if op == 'exec' and event.get('answer') is not None:
            text=event['answer'].get('output',{}).get('output','')
            lines=text.splitlines()
            index=next((i for i,line in enumerate(lines) if 'error:' in line or 'unsolved goals' in line),None)
            if index is not None:
                errors.append({'entry':row['entry'],'seconds':round(clock/1000,3),
                    'feedback_excerpt':'\n'.join(lines[index:index+12])[:1600]})
    result={'run':args.run_root.name,'recorded_seconds':round(clock/1000,3),
            'time_checks':time_checks,'time_tool_returns':time_tool_returns,'last_compiler_errors':errors[-3:],
            'actual_questions':questions,'public_submission':state.get('result',{}).get('value',{}).get('submission'),
            'grade':{key:state['grade']['value'].get(key) for key in ['passed','total','status']}}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(result,ensure_ascii=False))

if __name__ == '__main__':
    main()
