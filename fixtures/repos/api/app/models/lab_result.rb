class LabResult < ApplicationRecord
  belongs_to :medical_case

  enum :panel, [:histology, :culture, :pcr, :allergy]
end
