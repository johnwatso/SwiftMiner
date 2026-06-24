// SwiftMiner Help Center - Article Interactivity and Table of Contents

document.addEventListener('DOMContentLoaded', () => {
  // 1. Table of Contents Active Section Tracker (Intersection Observer)
  const headings = document.querySelectorAll('.kb-content h2[id], .kb-content h3[id]');
  const tocLinks = document.querySelectorAll('.toc-link');

  if (headings.length > 0 && tocLinks.length > 0) {
    const observerOptions = {
      root: null,
      rootMargin: '-10% 0px -75% 0px',
      threshold: 0
    };

    const observer = new IntersectionObserver((entries) => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          const id = entry.target.getAttribute('id');
          tocLinks.forEach(link => {
            if (link.getAttribute('href') === `#${id}`) {
              link.classList.add('active');
            } else {
              link.classList.remove('active');
            }
          });
        }
      });
    }, observerOptions);

    headings.forEach(heading => observer.observe(heading));
  }


});
