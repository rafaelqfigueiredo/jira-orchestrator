<template>
  <header class="case-header">
    <h1>{{ label }}</h1>
    <p v-if="closedAt">Closed {{ closedAt }}</p>
  </header>
</template>

<script setup lang="ts">
// One case, so one kind. Deliberately not a listing: the header reads the kind
// the case already has and shows the label for it.
const props = defineProps<{ caseType: string; closedAt?: string }>()
const label = props.caseType === "second_opinion" ? "Second opinion" : props.caseType
</script>
