import sys, json, time, torch
from transformers import AutoProcessor, AutoModelForMultimodalLM
mid, s, n, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
proc = AutoProcessor.from_pretrained(mid); model = AutoModelForMultimodalLM.from_pretrained(mid, dtype=torch.bfloat16).to('mps').eval()
prompt = "Transcribe the following speech segment in Bengali into Bengali text. Follow these specific instructions for formatting the answer:\n* Only output the transcription, with no newlines.\n* When transcribing numbers, write the digits, i.e. write 1.7 and not one point seven, and write 3 instead of three."
man = json.load(open(f'eval/{s}/manifest.json'))[:n]; hyps = {}; t0 = time.time()
for x in man:
    msgs = [{"role": "user", "content": [{"type": "text", "text": prompt}, {"type": "audio", "audio": f"eval/{s}/{x['wav']}"}]}]
    inp = proc.apply_chat_template(msgs, tokenize=True, return_dict=True, return_tensors="pt", add_generation_prompt=True).to('mps')
    with torch.no_grad(): o = model.generate(**inp, max_new_tokens=300, do_sample=False)
    hyps[x['wav']] = proc.decode(o[0][inp['input_ids'].shape[-1]:], skip_special_tokens=True).strip()
json.dump(hyps, open(out, 'w'), ensure_ascii=False); print(f"{s}: {time.time()-t0:.0f}s for {len(man)} utts")
