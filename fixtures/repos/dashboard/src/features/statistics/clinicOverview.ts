// The overview tile a clinic lands on: one bar per kind of case, in this order.
// Kept in step with the API by hand, which is why a new kind has to be added
// here as well.
const CASE_TYPE_LABELS: Record<string, string> = {
  first_visit: "First visit",
  reopened: "Reopened",
  second_opinion: "Second opinion"
}

export function overviewBars(counts: Record<string, number>) {
  return Object.keys(CASE_TYPE_LABELS).map((caseType) => ({
    caseType,
    label: CASE_TYPE_LABELS[caseType],
    value: counts[caseType] ?? 0
  }))
}
