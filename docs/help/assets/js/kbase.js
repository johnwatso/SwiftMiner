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

  // 2. Feedback Widget Submission Handler
  const feedbackWidget = document.querySelector('.feedback-widget');
  if (feedbackWidget) {
    const buttons = feedbackWidget.querySelectorAll('.feedback-btn');
    buttons.forEach(btn => {
      btn.addEventListener('click', () => {
        feedbackWidget.innerHTML = `
          <p style="color: var(--blue); font-weight: 600; margin: 0; padding: 0.5rem 0;">
            <i class="ph-bold ph-check-circle" style="vertical-align: middle; margin-right: 0.25rem;"></i>
            Thank you for your feedback!
          </p>
        `;
      });
    });
  }
});
