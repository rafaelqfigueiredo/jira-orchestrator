# The clinic-facing numbers. Every figure here is grouped by the kind of case,
# because that is the split clinics ask about when they renew.
class CaseStatistics
  def initialize(clinic, month)
    @clinic = clinic
    @month = month
  end

  def cases_by_kind
    scope.group(:case_type).count
  end

  def headline
    {
      first_visit: cases_by_kind.fetch("first_visit", 0),
      reopened: cases_by_kind.fetch("reopened", 0),
      second_opinion: cases_by_kind.fetch("second_opinion", 0)
    }
  end

  private

  def scope
    MedicalCase.where(clinic: @clinic).where(created_at: @month.all_month)
  end
end
