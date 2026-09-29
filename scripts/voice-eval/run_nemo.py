import sys, json, time, logging
logging.disable(logging.WARNING)
import nemo.collections.asr as nemo_asr
m, out_prefix = sys.argv[1], sys.argv[2]
model = nemo_asr.models.ASRModel.restore_from(m, map_location='cpu').eval()
for s in ['fleurs150','subakko150']:
    man = json.load(open(f'eval/{s}/manifest.json')); paths = [f'eval/{s}/{x["wav"]}' for x in man]
    t = time.time(); res = model.transcribe(paths, batch_size=8, verbose=False)
    res = res[0] if isinstance(res, tuple) else res
    texts = [r.text if hasattr(r,'text') else r for r in res]
    json.dump({x['wav']: t for x, t in zip(man, texts)}, open(f'eval/{s}_{out_prefix}.json','w'), ensure_ascii=False)
    print(s, f"{time.time()-t:.0f}s")
