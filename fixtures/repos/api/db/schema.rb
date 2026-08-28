ActiveRecord::Schema[7.1].define(version: 2026_02_11_090000) do
  create_table "medical_cases" do |t|
    t.bigint "clinic_id", null: false
    t.bigint "patient_id", null: false
    t.integer "case_type", null: false
    t.integer "closure_reason"
    t.datetime "closed_at"
    t.datetime "created_at", null: false
  end

  create_table "lab_results" do |t|
    t.bigint "medical_case_id", null: false
    t.integer "panel", null: false
    t.datetime "created_at", null: false
  end
end
