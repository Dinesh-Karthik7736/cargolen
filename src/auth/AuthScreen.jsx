import { useRef, useState } from 'react';
import { ArrowRight, Check, FileText, LockKeyhole, PackageCheck, ShieldCheck, Ship } from 'lucide-react';
import './AuthScreen.css';

export default function AuthScreen({ supabase, onPasswordRecovery, onSignOut }) {
  const [mode, setMode] = useState('sign-in');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const errorRef = useRef(null);

  const submit = async (event) => {
    event.preventDefault();
    setError('');
    setNotice('');
    setBusy(true);
    try {
      if (mode === 'reset') {
        const { error: resetError } = await supabase.auth.resetPasswordForEmail(email, {
          redirectTo: window.location.origin,
        });
        if (resetError) throw resetError;
        setNotice('If this account exists, a password reset link has been sent to its work email.');
      } else {
        const { error: signInError } = await supabase.auth.signInWithPassword({ email, password });
        if (signInError) throw signInError;
      }
    } catch (cause) {
      setError(mode === 'reset' ? cause.message : 'Sign-in failed. Check your work email and password, then try again.');
      requestAnimationFrame(() => errorRef.current?.focus());
    } finally {
      setBusy(false);
    }
  };

  return <main className="auth-shell">
    <div className="auth-layout">
      <aside className="auth-story" aria-label="CargoLens shipment document review">
        <div className="auth-story-kicker"><span className="auth-live-dot"/> DOCUMENT WORKSPACE</div>
        <div className="auth-story-copy">
          <span className="auth-story-eyebrow">A clearer way to review</span>
          <h2>From shipment documents to confident decisions.</h2>
          <p>Keep invoices, packing lists and bills of lading together in one focused workspace.</p>
        </div>
        <div className="auth-visual" aria-hidden="true">
          <div className="auth-visual-orbit orbit-one"/><div className="auth-visual-orbit orbit-two"/>
          <div className="auth-route"><span/><i/><span/></div>
          <div className="auth-document document-back"><FileText size={19}/><span/><span/><span/></div>
          <div className="auth-document document-front"><div className="auth-document-icon"><FileText size={17}/></div><div><b>Shipment documents</b><small>One review workspace</small></div><span className="auth-document-check"><Check size={13}/></span><div className="auth-document-progress"><i/></div></div>
          <div className="auth-visual-stamp"><PackageCheck size={17}/><span>Ready to review</span></div>
          <div className="auth-visual-ship"><Ship size={22}/></div>
        </div>
        <div className="auth-story-foot"><ShieldCheck size={15}/><span>Private workspace</span><i/><span>Built for careful review</span></div>
      </aside>
      <section className="auth-card" aria-label="Sign in">
        <div className="auth-brand"><span className="auth-brand-mark"><Ship size={20}/></span><span>Cargo<span>Lens</span></span><small>IMPORT OPERATIONS</small></div>
        {onPasswordRecovery ? <PasswordRecovery supabase={supabase} onSignOut={onSignOut}/> : <>
          <div className="auth-heading"><span className="auth-lock"><LockKeyhole size={17}/></span><h1>{mode === 'reset' ? 'Reset your password' : 'Welcome back'}</h1><p>{mode === 'reset' ? 'We’ll send a secure reset link to your work email.' : 'Sign in with your Company A work account.'}</p></div>
          {error&&<div ref={errorRef} className="auth-message error" role="alert" tabIndex="-1"><b>We couldn’t sign you in</b><span>{error}</span></div>}
          {notice&&<div className="auth-message success" role="status">{notice}</div>}
          <form onSubmit={submit} className="auth-form">
            <label htmlFor="auth-email">Work email</label>
            <input id="auth-email" type="email" autoComplete="username" required value={email} onChange={e=>setEmail(e.target.value)} placeholder="you@company.com" disabled={busy}/>
            {mode==='sign-in'&&<><div className="auth-password-label"><label htmlFor="auth-password">Password</label><button type="button" onClick={()=>{setError('');setNotice('');setMode('reset')}}>Forgot password?</button></div><input id="auth-password" type="password" autoComplete="current-password" required value={password} onChange={e=>setPassword(e.target.value)} placeholder="Enter your password" disabled={busy}/></>}
            <button className="auth-submit" type="submit" disabled={busy}>{busy?(mode==='reset'?'Sending link…':'Signing in…'):(mode==='reset'?'Send reset link':'Sign in')}<ArrowRight size={16}/></button>
          </form>
          {mode==='reset'&&<button className="auth-back" type="button" onClick={()=>{setMode('sign-in');setError('');setNotice('')}}>Back to sign in</button>}
          <div className="auth-footer"><LockKeyhole size={13}/><span>Access is limited to invited Company A staff.</span></div>
        </>}
      </section>
    </div>
    <span className="auth-region">Private shipment workspace <i/> Invited staff only</span>
  </main>;
}

function PasswordRecovery({ supabase, onSignOut }) {
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [done, setDone] = useState(false);
  const submit = async (event) => {
    event.preventDefault(); setBusy(true); setError('');
    const { error: updateError } = await supabase.auth.updateUser({ password });
    if (updateError) setError(updateError.message); else setDone(true);
    setBusy(false);
  };
  return <>
    <div className="auth-heading"><span className="auth-lock"><LockKeyhole size={17}/></span><h1>{done?'Password updated':'Choose a new password'}</h1><p>{done?'Your password was changed. Sign in again to continue.':'Use at least 12 characters and avoid reusing another password.'}</p></div>
    {error&&<div className="auth-message error" role="alert">{error}</div>}
    {!done?<form className="auth-form" onSubmit={submit}><label htmlFor="new-password">New password</label><input id="new-password" type="password" autoComplete="new-password" minLength="12" required value={password} onChange={e=>setPassword(e.target.value)}/><button className="auth-submit" type="submit" disabled={busy}>{busy?'Updating…':'Update password'}<ArrowRight size={16}/></button></form>:<button className="auth-submit" onClick={onSignOut}>Return to sign in<ArrowRight size={16}/></button>}
  </>;
}

