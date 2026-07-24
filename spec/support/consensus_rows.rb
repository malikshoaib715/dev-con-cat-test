# Stand-ins for the two records the consensus engine reads. The engine touches a
# layer result's status, verdict, detail and recorded signals, and a layer policy's
# key, promotion flag and weight overrides — nothing else — so its rules can be
# specced without a database. The real records' shapes are covered by the model
# specs and by spec/services/consensus/policy_spec.rb.
ScoredRow = Data.define(:layer_key, :status, :verdict, :detail, :raw_response)
PolicyOverride = Data.define(:layer_key, :treat_as_hard_stop, :weight_overrides)
