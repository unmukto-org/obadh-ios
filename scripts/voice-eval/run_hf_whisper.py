import sys, json, time, torch, soundfile as sf
from transformers import WhisperForConditionalGeneration, WhisperProcessor
m, man_path, out = sys.argv[1:4]
dev = 'mps'; p = WhisperProcessor.from_pretrained(m)
model = WhisperForConditionalGeneration.from_pretrained(m, torch_dtype=torch.float16).to(dev).eval()
man = json.load(open(man_path)); base = man_path.rsplit('/',1)[0]; hyps = {}; toks = 0; t0 = time.time()
for x in man:
    a, _ = sf.read(f"{base}/{x['wav']}", dtype='float32')
    f = p(a, sampling_rate=16000, return_tensors='pt').input_features.to(dev, torch.float16)
    with torch.no_grad(): ids = model.generate(f, language='bn', task='transcribe', num_beams=1, max_new_tokens=440)
    toks += ids.shape[1]; hyps[x['wav']] = p.batch_decode(ids, skip_special_tokens=True)[0]
json.dump(hyps, open(out,'w'), ensure_ascii=False)
aud = sum(x['dur'] for x in man); print(f"{m}: {time.time()-t0:.0f}s  tokens/s-of-audio {toks/aud:.1f}")
