import time, torch, logging, os
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
logging.disable(logging.WARNING)
import nemo.collections.asr as nemo_asr
m = nemo_asr.models.ASRModel.restore_from('models/hishab-conformer/titu_stt_bn_conformer_large.nemo', map_location='cpu')
print('params', sum(p.numel() for p in m.parameters())/1e6, 'M')
dev = 'mps'; m = m.to(dev).train()
opt = torch.optim.AdamW(m.parameters(), lr=1e-5)
B, secs = 16, 10.0; T = int(16000*secs)
sig = torch.randn(B, T, device=dev) * 0.05; ln = torch.full((B,), T, device=dev, dtype=torch.long)
V = m.decoder.num_classes_with_blank - 1
tgt = torch.randint(1, V, (B, 60), device=dev); tl = torch.full((B,), 60, device=dev, dtype=torch.long)
for i in range(6):
    t = time.time()
    with torch.autocast(device_type='mps', dtype=torch.bfloat16):
        lp, el, _ = m.forward(input_signal=sig, input_signal_length=ln)
    loss = m.loss(log_probs=lp.float(), targets=tgt, input_lengths=el, target_lengths=tl)
    opt.zero_grad(); loss.backward(); opt.step(); torch.mps.synchronize()
    print(f"step {i}: {time.time()-t:.2f}s  ({B*secs:.0f}s audio)")
