import { useState } from "react";
import AuthScreen from "./screens/AuthScreen";
import HomeScreen from "./screens/HomeScreen";
import ResultScreen from "./screens/ResultScreen";
import HistoryScreen from "./screens/HistoryScreen";
import PolicyPrivacyScreen from "./screens/PolicyPrivacyScreen";
import PolicyTermsScreen from "./screens/PolicyTermsScreen";
import AboutScreen from "./screens/AboutScreen";
import VerificationModal from "./components/VerificationModal";

export type Screen =
  | "auth"
  | "home"
  | "result"
  | "history"
  | "privacy"
  | "terms"
  | "about";

export type NavTab = "home" | "history" | "about";

export default function App() {
  const [screen, setScreen] = useState<Screen>("auth");
  const [activeTab, setActiveTab] = useState<NavTab>("home");
  const [showVerification, setShowVerification] = useState(false);

  const navigate = (s: Screen) => {
    setScreen(s);
    if (s === "home" || s === "history" || s === "about") {
      setActiveTab(s as NavTab);
    }
  };

  const handleFetchResult = () => {
    setShowVerification(true);
    setTimeout(() => {
      setShowVerification(false);
      navigate("result");
    }, 3200);
  };

  const mainScreens: Screen[] = ["home", "history", "result", "privacy", "terms", "about"];
  const showNav = mainScreens.includes(screen);

  return (
    <div className="min-h-screen flex items-center justify-center" style={{ background: "#E8EDF2" }}>
      {/* Phone shell */}
      <div
        className="relative flex flex-col overflow-hidden"
        style={{
          width: 390,
          minHeight: 844,
          maxHeight: "100vh",
          background: "#F8FAFC",
          borderRadius: 40,
          boxShadow: "0 32px 80px rgba(10,37,64,0.22), 0 0 0 1px rgba(10,37,64,0.08)",
        }}
      >
        {/* Status bar */}
        <div
          className="flex items-center justify-between px-6 pt-3 pb-1 flex-shrink-0"
          style={{ background: "#0A2540" }}
        >
          <span className="text-white text-xs font-medium" style={{ fontFamily: "DM Sans" }}>9:41</span>
          <div className="flex gap-1 items-center">
            <svg width="16" height="12" viewBox="0 0 16 12" fill="white" opacity={0.9}>
              <rect x="0" y="4" width="3" height="8" rx="0.5"/>
              <rect x="4.5" y="2.5" width="3" height="9.5" rx="0.5"/>
              <rect x="9" y="1" width="3" height="11" rx="0.5"/>
              <rect x="13.5" y="0" width="2.5" height="12" rx="0.5"/>
            </svg>
            <svg width="15" height="12" viewBox="0 0 15 12" fill="white" opacity={0.9}>
              <path d="M7.5 2.5C9.8 2.5 11.8 3.5 13.2 5.1L14.5 3.8C12.7 1.9 10.2 0.7 7.5 0.7C4.8 0.7 2.3 1.9 0.5 3.8L1.8 5.1C3.2 3.5 5.2 2.5 7.5 2.5Z"/>
              <path d="M7.5 5.5C9 5.5 10.3 6.1 11.3 7.1L12.6 5.8C11.2 4.5 9.4 3.7 7.5 3.7C5.6 3.7 3.8 4.5 2.4 5.8L3.7 7.1C4.7 6.1 6 5.5 7.5 5.5Z"/>
              <circle cx="7.5" cy="10" r="1.8"/>
            </svg>
            <div className="flex items-center gap-0.5">
              <div className="rounded-sm" style={{ width: 22, height: 11, border: "1.5px solid rgba(255,255,255,0.8)", padding: 1.5, display: "flex", alignItems: "center" }}>
                <div className="rounded-sm" style={{ width: "78%", height: "100%", background: "#00D4B1" }}/>
              </div>
            </div>
          </div>
        </div>

        {/* Screen content */}
        <div className="flex-1 overflow-y-auto" style={{ scrollbarWidth: "none" }}>
          {screen === "auth" && <AuthScreen onLogin={() => navigate("home")} />}
          {screen === "home" && <HomeScreen onFetch={handleFetchResult} onNavigate={navigate} />}
          {screen === "result" && <ResultScreen onBack={() => navigate("home")} />}
          {screen === "history" && <HistoryScreen onViewResult={() => navigate("result")} onNavigate={navigate} />}
          {screen === "privacy" && <PolicyPrivacyScreen onBack={() => navigate("about")} />}
          {screen === "terms" && <PolicyTermsScreen onBack={() => navigate("about")} />}
          {screen === "about" && <AboutScreen onNavigate={navigate} />}
        </div>

        {/* Bottom nav */}
        {showNav && screen !== "result" && screen !== "privacy" && screen !== "terms" && (
          <BottomNav active={activeTab} onNavigate={(tab) => { setActiveTab(tab); navigate(tab); }} />
        )}

        {/* Verification modal */}
        {showVerification && <VerificationModal />}
      </div>
    </div>
  );
}

function BottomNav({ active, onNavigate }: { active: NavTab; onNavigate: (t: NavTab) => void }) {
  const tabs: { id: NavTab; label: string; icon: React.ReactNode }[] = [
    {
      id: "home",
      label: "Check Result",
      icon: (
        <svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
          <circle cx="9" cy="9" r="6"/>
          <path d="M13.5 13.5L17 17"/>
        </svg>
      ),
    },
    {
      id: "history",
      label: "History",
      icon: (
        <svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
          <rect x="3" y="4" width="14" height="13" rx="2"/>
          <path d="M7 4V2M13 4V2M3 8h14"/>
        </svg>
      ),
    },
    {
      id: "about",
      label: "About & Legal",
      icon: (
        <svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
          <circle cx="10" cy="10" r="7.5"/>
          <path d="M10 9v5M10 6.5v.5"/>
        </svg>
      ),
    },
  ];

  return (
    <div
      className="flex-shrink-0 flex"
      style={{
        background: "#fff",
        borderTop: "1px solid #E2E8F0",
        paddingBottom: 20,
      }}
    >
      {tabs.map((t) => {
        const isActive = active === t.id;
        return (
          <button
            key={t.id}
            onClick={() => onNavigate(t.id)}
            className="flex-1 flex flex-col items-center gap-1 pt-3 pb-1 transition-colors"
            style={{ color: isActive ? "#0A2540" : "#94A3B8", background: "none", border: "none", cursor: "pointer" }}
          >
            <div style={{ color: isActive ? "#00D4B1" : "#CBD5E1" }}>{t.icon}</div>
            <span
              className="text-xs font-medium"
              style={{ color: isActive ? "#0A2540" : "#94A3B8", fontFamily: "DM Sans", fontSize: 10 }}
            >
              {t.label}
            </span>
            {isActive && (
              <div style={{ width: 4, height: 4, borderRadius: "50%", background: "#00D4B1", marginTop: 1 }} />
            )}
          </button>
        );
      })}
    </div>
  );
}
