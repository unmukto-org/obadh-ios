import json, re, sys, unicodedata, jiwer
def norm(s):
    s = unicodedata.normalize('NFC', s)
    s = s.replace('‌','').replace('‍','')
    s = re.sub(r"[।॥,.;:!?\"'“”‘’()\[\]{}\-–—…/]", ' ', s)
    return re.sub(r'\s+', ' ', s).strip().lower()
def score(manifest, hyps):
    refs = [norm(m['ref']) for m in manifest]; hs = [norm(hyps.get(m['wav'], '')) for m in manifest]
    return jiwer.wer(refs, hs)*100, jiwer.cer(refs, hs)*100
if __name__ == '__main__':
    man = json.load(open(sys.argv[1])); hyps = json.load(open(sys.argv[2]))
    w, c = score(man, hyps); print(f"WER {w:.2f}  CER {c:.2f}")
