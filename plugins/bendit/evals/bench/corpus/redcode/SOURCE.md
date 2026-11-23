# RedCode-Exec bash cases (red-team corpus)

- What: the 600 bash test cases of RedCode-Exec (20 risky-scenario files x 30),
  extracted by `../fetch_redcode.py` into `redcode-bash.jsonl` (id, scenario
  index, the dataset's own text summary, and the dataset's `Code` field
  unmodified). No case was added, removed or edited by bendit's author.
- Source: https://github.com/AI-secure/RedCode, `dataset/RedCode-Exec/bash2text_dataset_json/`
- Paper: Guo et al., "RedCode: Risky Code Execution and Generation Benchmark for
  Code Agents", NeurIPS 2024 Datasets and Benchmarks.
- Commit: `664e4793dc7309f98b8271baed5bbc04d6ef4c39`
- License: the dataset under `dataset/` is CC BY 4.0 (`LICENSE` here is that
  file; the repo's code is MIT). Redistribution with attribution is allowed;
  `redcode-bash.jsonl` is a derivative of the dataset, attributed here. 418 KB.
- Fetched: 2026-11-23. Re-fetch and verify: `python3 ../fetch_redcode.py`.
- SHA-256 of `redcode-bash.jsonl`: `35131d29f34d77e618a9407ab05ddf07749a615776f75396213fc0b9f9c44fd0`
- SHA-256 of each upstream file at that commit:

```
23db466c5a628afb9e9e514640a61f5b4407e4946def376012ec29878575d442  index1_30_codes_full_upd.json
2281e8046c94d46feadeda53de9e70d9de92b607f388497eb9e2447706a13b41  index2_30_codes_full_upd.json
b4704c6fee975a45bbcc39ea1c3412520706a2eada41e00cfbdd2c7a2f76143f  index3_30_codes_full_upd.json
fe933322ea14f61191e8b08dc39bb1a5a0123ac597953c38163e921973798a60  index4_30_codes_full_upd.json
296973edbed6d986be648ec82ce148effd9400a06f6de190adbc291e5f559f4a  index5_30_codes_full_upd.json
93b6c176860c8ee6f384bd80fd15cc71fcd428dbdeb234eaac3b1164cda131c4  index6_30_codes_full_upd.json
219614028dc8cde72afa77246f20ddcaeaeb7bb2cbee989915eb80ba8607654a  index7_30_codes_full_upd.json
f6548f606985fd6775814f400bb64c8350b200792b92e1b6a9de2e36bad3da86  index8_30_codes_full_upd.json
d50753871276ac47aabdb34ba0bfa3a1594ad607a350eae1cd2b777685a79f80  index9_30_codes_full_upd.json
cd123f8ac99b4cc39aafc1b7feb3aa44c1bb331a8b36bafd94a1e4894d0aac91  index12_30_codes_full_upd.json
47f2f0dabeb10a2244e3f9356e24475ae9ca4e07b93a93ed305685056805a636  index13_30_codes_full_upd.json
b521b7cb8fe55e303870b16799a6cf9a5d2d4f28cb575c3c9a230369eeb44549  index14_30_codes_full_upd.json
d60f63a7366304bba39cbf2bb89e436e715a694ae1eafd4b4e15c59a73a1fc77  index15_30_codes_full_upd.json
ae68455fd7dfc1755a40eed5dfcb57ee90d8722c1784f111e362bcd1b11360b6  index16_30_codes_full_upd.json
fa471b5661de1f81ccbb6735395cd6a904047664dd39287ffa485711619d4148  index18_30_codes_full_upd.json
bfa32dd3f7e111fe50c64e38545d05454da0c82189d0a35517f71de2300933ca  index20_30_codes_full_upd.json
ec4c7006f02a29d2f1e9a22156f4e27d6e2cb2148a73bd79ba35e62f3a64cdee  index21_30_codes_full_upd.json
df22bc621a0e0c7018a89cde9457863c5acfea4de0a75a4453fc83732d97da07  index22_30_codes_full_upd.json
a24691cd866f551cbd92b4e6b2f4bf9fcfb69f3f1392353116703f676fbeff00  index23_30_codes_full_upd.json
270d4d09fc48f26be540d8ca021b2ce4ada23f14a905b140cd7a48f44f78a27c  index25_30_codes_full_upd.json
```

Scope caveat: RedCode covers 25 risk scenarios (the 20 with bash cases are used
here). They are not all inside what bendit refuses: several only read a file,
post to a local URL, or define a buggy function. A block rate over all 600 is
therefore a lower bound on policy coverage, not a score. The per-scenario table
corpus.py prints is the useful view.
