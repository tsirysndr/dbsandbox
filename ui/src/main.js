import { mount } from 'svelte';
import App from './App.svelte';
mount(App, {
  target: document.getElementById('app'),
  props: {
    token: document.querySelector('meta[name="dbsandbox-token"]').content,
  },
});
