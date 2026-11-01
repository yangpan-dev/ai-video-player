<script setup lang="ts">
defineProps<{ name: 'sidebar' | 'folder' | 'settings' | 'plus' | 'captions' | 'close' | 'brightness' | 'minimal' }>()
const paths = {
  sidebar: 'M8 3v18M3 3h18v18H3z',
  folder: 'M3 7V5h6l2 2h10v12H3z',
  settings: 'M9 3h6l1 3 3 1 2 5-2 5-3 1-1 3H9l-1-3-3-1-2-5 2-5 3-1z M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0',
  plus: 'M12 5v14M5 12h14',
  captions: 'M3 5h18v14H3z M10 9H7v6h3 M17 9h-3v6h3',
  close: 'm6 6 12 12M6 18 18 6',
  brightness: 'M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0 M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5 19 19M5 19l1.5-1.5M17.5 6.5 19 5',
  minimal: 'M3 5h18v14H3z M7 9h10v6H7z'
}
</script>

<template>
  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path :d="paths[name]" /></svg>
</template>
