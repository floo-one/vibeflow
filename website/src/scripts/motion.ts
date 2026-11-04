// One GSAP setup for the whole site: ScrollTrigger registered once, and the media queries every
// section uses so reduced motion is honoured in one place.
import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { ScrollToPlugin } from 'gsap/ScrollToPlugin';

gsap.registerPlugin(ScrollTrigger, ScrollToPlugin);
// Phones: the address bar showing or hiding changes the viewport height on every scroll direction
// change; recalculating every trigger then makes pinned and snapped sections jump.
ScrollTrigger.config({ ignoreMobileResize: true });

export const MOTION = '(prefers-reduced-motion: no-preference)';
export const STILL = '(prefers-reduced-motion: reduce)';
export const EASE = 'power3.out';

export { gsap, ScrollTrigger };
