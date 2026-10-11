import pandas as pd, io, soundfile as sf, numpy as np, json, os, random
d = pd.read_parquet('eval/fleurs_bn_test.parquet')
d = d.drop_duplicates('transcription').reset_index(drop=True)
random.seed(7); idx = sorted(random.sample(range(len(d)), 150))
os.makedirs('eval/fleurs150', exist_ok=True); manifest = []
for i in idx:
    r = d.iloc[i]; a, sr = sf.read(io.BytesIO(r['audio']['bytes']), dtype='float32')
    if a.ndim > 1: a = a.mean(1)
    assert sr == 16000, sr
    name = f"fleurs_{r['id']}.wav"; sf.write(f'eval/fleurs150/{name}', a, 16000, subtype='PCM_16')
    manifest.append({'wav': name, 'ref': r['raw_transcription'], 'dur': len(a)/16000})
json.dump(manifest, open('eval/fleurs150/manifest.json','w'), ensure_ascii=False, indent=0)
print(len(manifest), 'utts', round(sum(m['dur'] for m in manifest)/60,1), 'min')
