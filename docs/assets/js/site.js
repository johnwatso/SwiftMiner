document.addEventListener('DOMContentLoaded', () => {
    const scrollContainer = document.querySelector('.snap-scroller');

    function resetScrollForFreshLoad() {
        if (!scrollContainer || window.location.hash) return;
        scrollContainer.scrollTo({ top: 0, left: 0, behavior: 'auto' });
    }

    resetScrollForFreshLoad();
    requestAnimationFrame(resetScrollForFreshLoad);
    window.addEventListener('pageshow', resetScrollForFreshLoad);

    const pageSections = scrollContainer ? Array.from(scrollContainer.querySelectorAll(':scope > section')) : [];
    const screenshotCards = scrollContainer ? Array.from(scrollContainer.querySelectorAll('.screenshot-card')) : [];

    // High-performance scroll tracking via IntersectionObserver
    // replacing the laggy scroll event listener and visibleScore getBoundingClientRect calls.
    if (scrollContainer && pageSections.length > 0) {
        const sectionObserver = new IntersectionObserver((entries) => {
            let activeSection = null;
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    activeSection = entry.target;
                }
            });
            if (activeSection) {
                pageSections.forEach(section => {
                    section.classList.toggle('is-current-section', section === activeSection);
                });
            }
        }, {
            root: scrollContainer,
            rootMargin: "-50% 0px -50% 0px",
            threshold: 0
        });
        pageSections.forEach(section => sectionObserver.observe(section));
    }

    if (scrollContainer && screenshotCards.length > 0) {
        const cardObserver = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    screenshotCards.forEach(card => {
                        card.classList.toggle('is-current-card', card === entry.target);
                    });
                }
            });
        }, {
            root: scrollContainer,
            rootMargin: "-45% 0px -45% 0px",
            threshold: 0
        });
        screenshotCards.forEach(card => cardObserver.observe(card));
    }

    // Immediately mark sections-ready so CSS states initialize cleanly
    document.body.classList.add('sections-ready');

    // Reveal on Scroll Initialization
    const observerOptions = {
        root: scrollContainer,
        threshold: 0.08,
        rootMargin: "0px 0px -30px 0px"
    };

    // Reveal once, then stop observing — avoids re-running transitions and
    // style recalcs on every scroll pass (a source of scroll jank).
    const observer = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                entry.target.classList.add('active');
                observer.unobserve(entry.target);
            }
        });
    }, observerOptions);

    document.querySelectorAll('.reveal').forEach(el => observer.observe(el));

    const privacyLock = document.querySelector('.privacy-lock');
    if (privacyLock) {
        const lockObserver = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    privacyLock.classList.add('is-locked');
                } else {
                    privacyLock.classList.remove('is-locked');
                }
            });
        }, {
            root: scrollContainer,
            threshold: 0.1,
            rootMargin: "0px 0px -40px 0px"
        });
        lockObserver.observe(privacyLock);
    }

    let particlesReady = false;
    
    const screenshotAssetVersion = '20260623';

    function applyTheme(isLight) {
        const theme = isLight ? 'light' : 'dark';
        document.querySelector('#theme-color').content = isLight ? '#f8fafc' : '#120d2b';
        [document.documentElement, document.body].forEach(element => {
            if (!element) return;
            element.classList.toggle('light', isLight);
            element.classList.toggle('dark', !isLight);
            element.dataset.theme = theme;
        });
        // Swap screenshots based on mode
        document.querySelectorAll('img[data-screenshot]').forEach(img => {
            const type = img.getAttribute('data-screenshot');
            img.src = `./assets/landing/${type}-${isLight ? 'light' : 'dark'}.webp?v=${screenshotAssetVersion}`;
        });

        // Re-initialize particles to update their colors
        if (particlesReady && typeof initParticles === 'function') {
            initParticles();
        }
    }

    // Sync toggle state and apply initial theme images on load
    const systemThemeQuery = window.matchMedia('(prefers-color-scheme: light)');
    applyTheme(systemThemeQuery.matches);

    // Follow OS theme changes.
    systemThemeQuery.addEventListener('change', (e) => {
        applyTheme(e.matches);
    });

    const themeToggleBtn = document.getElementById('theme-toggle');
    if (themeToggleBtn) {
        themeToggleBtn.addEventListener('click', () => {
            const isLight = !document.documentElement.classList.contains('light');
            applyTheme(isLight);
        });
    }

    // Particle Canvas Background
    const canvas = document.getElementById('particles');
    const ctx = canvas.getContext('2d');
    let width, height, particles;
    let particleRafId = null;
    const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    function initParticles() {
        width = canvas.width = window.innerWidth;
        height = canvas.height = window.innerHeight;
        particles = [];
        const particleCount = Math.min(Math.floor(width / 32), 50); // Scale based on screen size
        const isLight = document.documentElement.classList.contains('light');

        for(let i = 0; i < particleCount; i++) {
            const rand = Math.random();
            let color = isLight ? 'rgba(147, 51, 234, 0.15)' : 'rgba(147, 51, 234, 0.4)'; // brand purple
            if (rand < 0.33) {
                color = isLight ? 'rgba(0, 180, 216, 0.15)' : 'rgba(0, 229, 255, 0.4)'; // cyan
            } else if (rand < 0.66) {
                color = isLight ? 'rgba(255, 0, 127, 0.12)' : 'rgba(255, 0, 127, 0.4)'; // neon magenta
            }
            particles.push({
                x: Math.random() * width,
                y: Math.random() * height,
                vx: (Math.random() - 0.5) * 0.4,
                vy: (Math.random() - 0.5) * 0.4,
                size: Math.random() * 1.5 + 0.5,
                color: color
            });
        }

        // In reduced-motion mode the loop never runs, so paint one static frame
        // (also keeps colors correct after a theme toggle).
        if (reduceMotion) {
            ctx.clearRect(0, 0, width, height);
            particles.forEach(p => {
                ctx.beginPath();
                ctx.arc(p.x, p.y, p.size, 0, Math.PI * 2);
                ctx.fillStyle = p.color;
                ctx.fill();
            });
        }
    }

    function animateParticles() {
        ctx.clearRect(0, 0, width, height);

        particles.forEach(p => {
            p.x += p.vx;
            p.y += p.vy;

            if(p.x < 0 || p.x > width) p.vx *= -1;
            if(p.y < 0 || p.y > height) p.vy *= -1;

            ctx.beginPath();
            ctx.arc(p.x, p.y, p.size, 0, Math.PI * 2);
            ctx.fillStyle = p.color;
            ctx.fill();
        });

        particleRafId = requestAnimationFrame(animateParticles);
    }

    function startParticles() {
        // Don't run the loop if the user prefers reduced motion or the tab is hidden.
        if (reduceMotion || document.hidden || particleRafId !== null) return;
        particleRafId = requestAnimationFrame(animateParticles);
    }

    function stopParticles() {
        if (particleRafId !== null) {
            cancelAnimationFrame(particleRafId);
            particleRafId = null;
        }
    }

    particlesReady = true;
    initParticles(); // paints a static frame when reduced-motion is set
    startParticles(); // no-op under reduced motion

    // Pause the animation loop whenever the tab is backgrounded.
    document.addEventListener('visibilitychange', () => {
        if (document.hidden) stopParticles();
        else startParticles();
    });

    // Debounce resize so repeated events (e.g. mobile URL-bar show/hide) don't thrash.
    let resizeTimer = null;
    window.addEventListener('resize', () => {
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(initParticles, 200);
    });
});

(function () {
    var links = Array.prototype.slice.call(document.querySelectorAll('[data-latest-download]'));
    if (!links.length) return;

    function apply(url, version, rawVersion) {
        links.forEach(function (link) {
            link.href = url;
        });
        if (version) {
            document.querySelectorAll('[data-latest-version]').forEach(function (el) {
                el.textContent = version;
            });
        }
        if (rawVersion) {
            document.querySelectorAll('[data-latest-version-raw]').forEach(function (el) {
                el.textContent = rawVersion;
            });
        }
    }

    fetch('https://api.github.com/repos/johnwatso/SwiftMiner/releases/latest', {
        headers: { 'Accept': 'application/vnd.github+json' }
    })
        .then(function (response) {
            return response.ok ? response.json() : Promise.reject();
        })
        .then(function (release) {
            var assets = release.assets || [];
            var zip = assets.find(function (asset) {
                return /^SwiftMiner-.*\.zip$/.test(asset.name || '');
            }) || assets.find(function (asset) {
                return /\.zip$/.test(asset.name || '');
            });

            if (zip && zip.browser_download_url) {
                var version = release.tag_name || '';
                var rawVersion = version.startsWith('v') ? version.substring(1) : version;
                apply(zip.browser_download_url, version, rawVersion);
            }
        })
        .catch(function () {
            // Keep the checked-in ZIP URL if GitHub's API is unavailable.
        });
})();
