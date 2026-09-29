import sys, json, time, soundfile as sf, sherpa_onnx
kind, model, tokens, man_path, out = sys.argv[1:6]
if kind == 'nemo': r = sherpa_onnx.OfflineRecognizer.from_nemo_ctc(model=model, tokens=tokens, num_threads=4, decoding_method='greedy_search')
else: r = sherpa_onnx.OfflineRecognizer.from_omnilingual_asr_ctc(model=model, tokens=tokens, num_threads=4)
man = json.load(open(man_path)); base = man_path.rsplit('/',1)[0]; hyps = {}; tot = 0; aud = 0
for m in man:
    a, _ = sf.read(f"{base}/{m['wav']}", dtype='float32'); t = time.time()
    s = r.create_stream(); s.accept_waveform(16000, a); r.decode_stream(s)
    hyps[m['wav']] = s.result.text; tot += time.time()-t; aud += m['dur']
json.dump(hyps, open(out,'w'), ensure_ascii=False); print(f"RTF {tot/aud:.3f} (4 threads)")
