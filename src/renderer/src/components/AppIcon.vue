<script setup lang="ts">
defineProps<{ name: 'sidebar' | 'folder' | 'settings' | 'plus' | 'captions' | 'close' }>()
const paths = {
  sidebar: 'M8 3v18M3 3h18v18H3z',
  folder: 'M3 7V5h6l2 2h10v12H3z',
  settings: 'M9 3h6l1 3 3 1 2 5-2 5-3 1-1 3H9l-1-3-3-1-2-5 2-5 3-1z M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0',
  plus: 'M12 5v14M5 12h14',
  captions: 'M3 5h18v14H3z M10 9H7v6h3 M17 9h-3v6h3',
  close: 'm6 6 12 12M6 18 18 6'
}
</script>

<template>
  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path :d="paths[name]" /></svg>
</template>
