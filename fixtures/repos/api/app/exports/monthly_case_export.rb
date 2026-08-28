# One row per case, sent to the clinic's accounting mailbox on the first of the
# month. The kind of case decides which column the row is counted in.
class MonthlyCaseExport
  COLUMNS = {
    "first_visit" => "First visit",
    "reopened" => "Reopened",
    "second_opinion" => "Second opinion"
  }.freeze

  def rows(clinic, month)
    MedicalCase.where(clinic: clinic, created_at: month.all_month).map do |medical_case|
      [medical_case.reference, COLUMNS.fetch(medical_case.case_type), medical_case.closed_at]
    end
  end
end
