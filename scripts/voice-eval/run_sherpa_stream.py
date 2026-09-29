import sys, json, time, numpy as np, soundfile as sf, sherpa_onnx
d, suffix, man_path, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
r = sherpa_onnx.OnlineRecognizer.from_transducer(
    encoder=f"{d}/am-onnx/encoder{suffix}.onnx", decoder=f"{d}/am-onnx/decoder.onnx", joiner=f"{d}/am-onnx/joiner{suffix}.onnx",
    tokens=f"{d}/lang/tokens.txt", num_threads=2, sample_rate=16000, decoding_method="modified_beam_search", max_active_paths=4, provider="cpu", model_type="zipformer2")
man = json.load(open(man_path)); base = man_path.rsplit('/',1)[0]; hyps = {}; tot = 0; aud = 0
for m in man:
    a, _ = sf.read(f"{base}/{m['wav']}", dtype='float32'); t = time.time(); s = r.create_stream()
    for i in range(0, len(a), 1600):
        s.accept_waveform(16000, a[i:i+1600])
        while r.is_ready(s): r.decode_stream(s)
    s.accept_waveform(16000, np.zeros(8000, np.float32)); s.input_finished()
    while r.is_ready(s): r.decode_stream(s)
    hyps[m['wav']] = r.get_result(s); tot += time.time()-t; aud += m['dur']
json.dump(hyps, open(out,'w'), ensure_ascii=False); print(f"RTF {tot/aud:.3f}")
