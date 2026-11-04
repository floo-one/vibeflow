// Homepage motion: the hero settles in on load and drifts back as the Shortcuts tour takes over,
// and the sections after it rise in once as they reach the screen. Reduced motion gets none of it;
// the CSS only hides the hero while this is known to run (.js and no-preference).
import { gsap, ScrollTrigger, EASE, MOTION } from './motion';

gsap.matchMedia().add(MOTION, () => {
  const hero = document.querySelector<HTMLElement>('.hero');
  if (hero) {
    gsap.fromTo(hero.children, { autoAlpha: 0, y: 28 }, { autoAlpha: 1, y: 0, duration: 1, ease: EASE, stagger: 0.09, delay: 0.05 });
    // Scrubbed on the section, never on its children, so it cannot fight the entrance.
    gsap.to(hero, {
      opacity: 0.15, y: -48, scale: 0.97, ease: 'none',
      scrollTrigger: { trigger: hero, start: 'top top', end: 'bottom top', scrub: 0.4 },
    });
  }

  const items = gsap.utils.toArray<HTMLElement>(
    '.kt-head, .show .copy, .show .scene, .ask-vis, .section-head, .cards > *, .extra, .table-box, .privacy-table, .faq, .final-inner',
  );
  gsap.set(items, { autoAlpha: 0, y: 36 });
  ScrollTrigger.batch(items, {
    start: 'top 88%',
    once: true,
    onEnter: (batch) =>
      gsap.to(batch, { autoAlpha: 1, y: 0, duration: 0.9, ease: EASE, stagger: 0.08, overwrite: true, clearProps: 'transform,opacity,visibility' }),
  });
});
