"""Build + load the diverse-industry judging set into Argilla for the user to label.
industry (24-label) + flags (6 multi-label), pre-filled from flash-lite (v10, the adopted model);
prod(nano) + flash-lite votes shown read-only. Filter metadata.nano_flash_agree=false for the juiciest cases."""
import json, os
import argilla as rg

HERE = os.path.dirname(os.path.abspath(__file__))
DATASET = "fsm-fit-judge-diverse"
INDUSTRIES = ["general_contracting","electrical","hvac","locksmith","mechanical_service","plumbing",
    "handyman","appliance_repair","flooring","junk_removal","painting","pest_control","pool_spa_service",
    "renovations","roofing","cleaning","arborist_tree_care","landscaping","lawn_care_maintenance",
    "snow_removal","computers_it","home_theater","security_alarm","other"]
FLAGS = ["on_site_work","labour_billing","scheduling","recurring_billing",
         "complex_multi_line_jobs","contract_based_billing"]

ws = json.load(open(os.path.join(HERE,"judge_worksheet.json"),encoding="utf-8"))
fl = json.load(open(os.path.join(HERE,"flashlite_pred.json"),encoding="utf-8"))
nano = json.load(open(os.path.join(HERE,"nano_pred.json"),encoding="utf-8"))

def tf(d): return ", ".join(k for k in FLAGS if d.get(k)) or "(none)"

client = rg.Argilla(api_url=os.environ.get("ARGILLA_API_URL","http://localhost:6900"),
                    api_key=os.environ.get("ARGILLA_API_KEY","argilla.apikey"))
settings = rg.Settings(
    guidelines=(
        "Label the TRUE FSM-fit industry (24 ids) and the 6 evidence flags for each account, from "
        "business_name + top_item_names (metrics are secondary). Classify by the ACTUAL work, not a "
        "matched word or the name; out-of-scope work (vehicle wash/detail, laundry, pet care, wholesale, "
        "consulting) = other, never a nearest-bucket. Empty/name-only -> other + all flags false. "
        "Flags: scheduling = would the business benefit from a VISIT CALENDAR (visit/appointment-based work, "
        "even one visit per customer); recurring_billing = SAME repeated service / explicit periodic language "
        "(reactive trade to repeat clients is NOT recurring); on_site_work = work at the customer's location; "
        "labour_billing = billed by time/labour/per-job; complex_multi_line = labour+parts+materials in one "
        "invoice; contract_based = high amount + very few lines. Suggestions are flash-lite (v10); three model "
        "votes (prod-nano v7, nano v10, flash-lite v10) are shown one per line so you can arbitrate. "
        "Tip: filter all3_agree=false for the cases worth your time."
    ),
    fields=[
        rg.TextField(name="business_name", title="Business name"),
        rg.TextField(name="top_item_names", title="Top item names"),
        rg.TextField(name="metrics", title="Metrics"),
        rg.TextField(name="model_votes", title="Model votes (one per line)"),
    ],
    questions=[
        rg.LabelQuestion(name="industry", title="Industry (true)", labels=INDUSTRIES),
        rg.MultiLabelQuestion(name="flags", title="FSM-fit flags (true)", labels=FLAGS),
        rg.TextQuestion(name="note", title="Note", required=False),
    ],
    metadata=[
        rg.TermsMetadataProperty(name="prod_industry"),
        rg.TermsMetadataProperty(name="nano_v10_industry"),
        rg.TermsMetadataProperty(name="flashlite_industry"),
        rg.TermsMetadataProperty(name="all3_agree", options=["true","false"]),
        rg.TermsMetadataProperty(name="tier", options=["none","weak","strong"]),
        rg.IntegerMetadataProperty(name="difficulty_score"),
    ],
)
existing = client.datasets(name=DATASET)
if existing is not None: existing.delete()
ds = rg.Dataset(name=DATASET, settings=settings, client=client); ds.create()

records, n_disagree = [], 0
for w in ws:
    f = fl.get(w["account_id"], {}); fi = f.get("industry"); ff = f.get("flags", {})
    nv = nano.get(w["account_id"], {}); ni = nv.get("industry"); nfl = nv.get("flags", {})
    all3 = (w["prod_industry"] == ni == fi)
    if not all3: n_disagree += 1
    m = w.get("metrics") or {}
    sug = [rg.Suggestion("industry", fi, agent="flashlite_v10")] if fi in INDUSTRIES else []
    sf = [k for k in FLAGS if ff.get(k)]
    if sf: sug.append(rg.Suggestion("flags", sf, agent="flashlite_v10"))
    votes = (f"prod-nano (v7):   {w['prod_industry']}  [{tf(w['prod_flags'])}]\n"
             f"nano (v10):       {ni}  [{tf(nfl)}]\n"
             f"flash-lite (v10): {fi}  [{tf(ff)}]")
    records.append(rg.Record(
        fields={
            "business_name": w.get("business_name") or "(none)",
            "top_item_names": w.get("items") or "(empty)",
            "metrics": " ".join(f"{k}={m.get(k)}" for k in
                ["invoice_count_30d","avg_invoice_amount","avg_line_items_per_invoice",
                 "repeat_customer_ratio","multi_address_work","b2b_clients_present","distinct_addresses"]),
            "model_votes": votes,
        },
        suggestions=sug,
        metadata={"prod_industry": w["prod_industry"], "nano_v10_industry": ni or "none",
                  "flashlite_industry": fi or "none", "all3_agree": str(all3).lower(),
                  "tier": w["prod_tier"], "difficulty_score": int(w["difficulty_score"])},
        id=w["account_id"]))
ds.records.log(records)
print(f"loaded {len(records)} into '{DATASET}' | all-3 disagree on industry: {n_disagree} (filter all3_agree=false)")
print("UI: http://localhost:6900")
