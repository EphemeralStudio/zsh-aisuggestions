/* ═══════════════════════════════════════════════════════════════════════════
   zsh-aisuggestions — Minimal site JavaScript
   ═══════════════════════════════════════════════════════════════════════════ */

document.addEventListener('DOMContentLoaded', function () {

  /* ─── Mobile nav toggle ──────────────────────────────────────────────── */
  var toggle = document.querySelector('.nav__toggle');
  var links = document.querySelector('.nav__links');

  if (toggle && links) {
    toggle.addEventListener('click', function () {
      toggle.classList.toggle('active');
      links.classList.toggle('active');
    });

    /* Close mobile nav when a link is clicked */
    links.querySelectorAll('a').forEach(function (link) {
      link.addEventListener('click', function () {
        toggle.classList.remove('active');
        links.classList.remove('active');
      });
    });
  }

  /* ─── Copy-to-clipboard buttons ──────────────────────────────────────── */
  document.querySelectorAll('.install__code-copy').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var code = btn.parentElement.querySelector('code');
      if (!code) return;
      var text = code.textContent.trim();

      if (navigator.clipboard) {
        navigator.clipboard.writeText(text).then(function () {
          btn.textContent = 'Copied!';
          setTimeout(function () { btn.textContent = 'Copy'; }, 2000);
        });
      } else {
        /* Fallback for older browsers */
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.select();
        document.execCommand('copy');
        document.body.removeChild(ta);
        btn.textContent = 'Copied!';
        setTimeout(function () { btn.textContent = 'Copy'; }, 2000);
      }
    });
  });

  /* ─── Scroll: shrink nav on scroll ───────────────────────────────────── */
  var nav = document.querySelector('.nav');
  if (nav) {
    window.addEventListener('scroll', function () {
      if (window.scrollY > 20) {
        nav.style.borderBottomColor = 'var(--border-light)';
      } else {
        nav.style.borderBottomColor = 'var(--border-color)';
      }
    });
  }

  /* ─── Terminal typing animation (hero) ───────────────────────────────── */
  var heroTerminal = document.querySelector('.hero-terminal-animated');
  if (heroTerminal) {
    var scenes = [
      {
        input: 'list all running docker containers',
        ghost: 'docker ps',
        label: 'Ctrl+G'
      },
      {
        input: 'git clone react',
        ghost: 'git clone https://github.com/facebook/react.git',
        label: 'Ctrl+G'
      },
      {
        input: 'dockr bilud -t myapp .',
        ghost: 'docker build -t myapp .',
        label: 'Ctrl+G'
      }
    ];

    var currentScene = 0;
    var inputEl = heroTerminal.querySelector('.terminal__command');
    var ghostEl = heroTerminal.querySelector('.terminal__ghost');
    var labelEl = heroTerminal.querySelector('.terminal__keylabel');

    function playScene() {
      var scene = scenes[currentScene];
      if (!inputEl || !ghostEl) return;

      /* Clear */
      inputEl.textContent = '';
      ghostEl.textContent = '';
      if (labelEl) labelEl.textContent = '';

      /* Type input */
      var i = 0;
      var typeInput = setInterval(function () {
        if (i < scene.input.length) {
          inputEl.textContent += scene.input[i];
          i++;
        } else {
          clearInterval(typeInput);
          /* Pause, then show ghost */
          setTimeout(function () {
            if (labelEl) labelEl.textContent = '  ' + scene.label;
            ghostEl.textContent = '';
            /* Type ghost text */
            inputEl.textContent = '';
            var j = 0;
            var typeGhost = setInterval(function () {
              if (j < scene.ghost.length) {
                ghostEl.textContent += scene.ghost[j];
                j++;
              } else {
                clearInterval(typeGhost);
                /* Pause then next scene */
                setTimeout(function () {
                  currentScene = (currentScene + 1) % scenes.length;
                  playScene();
                }, 3000);
              }
            }, 30);
          }, 800);
        }
      }, 50);
    }

    /* Start after a brief delay */
    setTimeout(playScene, 1000);
  }

});
