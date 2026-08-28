class MedicalCase < ApplicationRecord
  belongs_to :clinic
  belongs_to :patient
  has_many :lab_results, dependent: :destroy

  # Every kind of case the product has. A case is created as one of these and
  # never changes kind: the billing package and the doctor queue both key off it.
  enum :case_type, [:first_visit, :reopened, :second_opinion]

  enum :closure_reason, [:treated, :referred, :withdrawn]

  scope :open_cases, -> { where(closed_at: nil) }
end
