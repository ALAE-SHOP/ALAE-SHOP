(() => {
  const ready = (async () => {
    if (!window.supabaseClient) return null;

    const { data, error } = await window.supabaseClient.auth.getSession();
    if (error) console.error("Supabase session error:", error);

    const session = data?.session || null;
    window.ALAE_AUTH = { session, currentUser: session?.user || null };

    const sync = (s) => {
      window.ALAE_AUTH = { session: s, currentUser: s?.user || null };
      updateAuthUI();
    };

    window.supabaseClient.auth.onAuthStateChange((_event, s) => sync(s));
    updateAuthUI();
    return session;
  })();

  window.ALAE_AUTH_READY = ready;

  function updateAuthUI() {
    const logged = !!window.ALAE_AUTH?.currentUser;
    document.querySelectorAll('[data-auth-profile]').forEach(e => e.style.display = logged ? 'inline-block' : 'none');
    document.querySelectorAll('[data-auth-login]').forEach(e => e.style.display = logged ? 'none' : 'inline-block');
    document.querySelectorAll('[data-auth-register]').forEach(e => e.style.display = logged ? 'none' : 'inline-block');
    document.querySelectorAll('[data-auth-logout]').forEach(e => e.style.display = logged ? 'inline-block' : 'none');
  }

  function isConfigured() {
    return !!window.supabaseClient &&
      typeof window.SUPABASE_KEY !== 'undefined' &&
      window.SUPABASE_KEY !== 'YOUR_SUPABASE_PUBLISHABLE_KEY';
  }

  function humanError(error) {
    const msg = String(error?.message || error || '');
    if (/invalid api key|apikey/i.test(msg)) {
      return 'مفتاح Supabase غير صحيح. افتح supabase-config.js وضع Publishable/Anon key الصحيح.';
    }
    if (/invalid login credentials/i.test(msg)) return 'البريد الإلكتروني أو كلمة المرور غير صحيحة.';
    if (/email not confirmed/i.test(msg)) return 'خاصك تأكد البريد الإلكتروني قبل تسجيل الدخول.';
    return msg || 'وقع خطأ، عاود المحاولة.';
  }

  function showMsg(msg, ok = false) {
    const el = document.getElementById('auth-msg');
    if (el) {
      el.textContent = msg;
      el.style.color = ok ? '#55eaff' : '#ff6b9d';
    }
  }

  document.addEventListener('DOMContentLoaded', async () => {
    await ready;

    const login = document.getElementById('loginForm');
    if (login) login.addEventListener('submit', async e => {
      e.preventDefault();

      if (!isConfigured()) {
        showMsg('خصك تحط Publishable/Anon key ديال Supabase فـ supabase-config.js.');
        return;
      }

      const fd = new FormData(login);
      const email = String(fd.get('email') || '').trim();
      const password = String(fd.get('password') || '');

      const { data, error } = await window.supabaseClient.auth.signInWithPassword({ email, password });
      if (error) {
        console.error(error);
        showMsg(humanError(error));
        return;
      }

      showMsg('تم تسجيل الدخول ✓', true);
      setTimeout(() => location.replace('index.html'), 250);
    });

    const reg = document.getElementById('registerForm');
    if (reg) reg.addEventListener('submit', async e => {
      e.preventDefault();

      if (!isConfigured()) {
        showMsg('خصك تحط Publishable/Anon key ديال Supabase فـ supabase-config.js.');
        return;
      }

      const fd = new FormData(reg);
      const username = String(fd.get('username') || '').trim();
      const fullName = String(fd.get('fullName') || '').trim();
      const email = String(fd.get('email') || '').trim();
      const password = String(fd.get('password') || '');
      const ref = new URLSearchParams(location.search).get('ref');

      const { data, error } = await window.supabaseClient.auth.signUp({
        email,
        password,
        options: {
          data: {
            username,
            full_name: fullName,
            referred_by: ref || null
          }
        }
      });

      if (error) {
        console.error(error);
        showMsg(humanError(error));
        return;
      }

      if (data?.session) {
        showMsg('تم إنشاء الحساب ✓', true);
        setTimeout(() => location.replace('index.html'), 300);
      } else {
        showMsg('تم إنشاء الحساب. تأكد من بريدك الإلكتروني إذا كان تأكيد البريد مفعلاً.', true);
      }
    });

    document.querySelectorAll('[data-auth-logout]').forEach(btn =>
      btn.addEventListener('click', async () => {
        await window.supabaseClient.auth.signOut();
        location.replace('login.html');
      })
    );
  });
})();