// LoudToast native core. Compiled by LoudToast.psm1 at import time via CodeDom against System32\WinMetadata
// (C# 5, .NET Framework). The COM interfaces below are undocumented; they were reconstructed from proxy/stub
// format strings and public PDB symbols of Windows 11 build 26200.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using Windows.Data.Xml.Dom;
using Windows.UI.Notifications;

namespace LoudToast
{
    // ---------- Quiet Hours / Do Not Disturb (QuietHours.dll, hosted by WpnUserService) ----------
    [ComImport, Guid("6bff4732-81ec-4ffb-ae67-b6c1bc29631f"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IQuietHoursSettings
    {
        [PreserveSig] int get_UserSelectedProfile([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int put_UserSelectedProfile([MarshalAs(UnmanagedType.LPWStr)] string id);
        [PreserveSig] int GetProfile([MarshalAs(UnmanagedType.LPWStr)] string id, out IQuietHoursProfile p);
        void GetAllProfileData(); void GetDisplayNameForProfile();
        [PreserveSig] int get_QuietMomentsManager(out IQuietMomentsManager m);
        [PreserveSig] int get_OffProfileId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int get_ActiveQuietMomentProfile([MarshalAs(UnmanagedType.LPWStr)] out string id);
        void SetActiveQuietMomentProfile();
        [PreserveSig] int get_ActiveProfile([MarshalAs(UnmanagedType.LPWStr)] out string id);
        void get_QuietHoursPinnedContactManager(); void SetQuietMomentsShowSummaryEnabled(); void GetQuietMomentsShowSummaryEnabled();
        [PreserveSig] int GetAlwaysAllowedApps(out int n, out IntPtr arr);
    }

    [ComImport, Guid("e813fe81-62b6-417d-b951-9d2e08486ac1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IQuietHoursProfile
    {
        void get_DisplayName(); void get_ProfileId();
        [PreserveSig] int GetSetting(int setting, out int value);
        [PreserveSig] int PutSetting(int setting, int value);
        void _7(); void GetAllowedContacts(); void AddAllowedContact(); void RemoveAllowedContact();
        [PreserveSig] int GetAllowedApps(out int n, out IntPtr arr);
        [PreserveSig] int AddAllowedApp([MarshalAs(UnmanagedType.LPWStr)] string aumid);
        [PreserveSig] int RemoveAllowedApp([MarshalAs(UnmanagedType.LPWStr)] string aumid);
    }

    [ComImport, Guid("b0217783-87b7-422c-b902-5c148c14f150"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IQuietMomentsManager
    {
        void GetAllQuietMomentModes(); void GetQuietMoment();
        [PreserveSig] int TurnOffCurrentlyActiveQuietMoment();
    }

    public static class Dnd
    {
        public const string Off = "Microsoft.QuietHoursProfile.Unrestricted";
        public const string PriorityOnly = "Microsoft.QuietHoursProfile.PriorityOnly";  // the Windows 11 "Do not disturb" toggle
        public const string AlarmsOnly = "Microsoft.QuietHoursProfile.AlarmsOnly";

        static IQuietHoursSettings Q()
        {
            return (IQuietHoursSettings)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("f53321fa-34f8-4b7f-b9a3-361877cb94cf")));
        }
        static IQuietHoursProfile P(string id) { IQuietHoursProfile p; Marshal.ThrowExceptionForHR(Q().GetProfile(id, out p)); return p; }
        static string[] Strings(int n, IntPtr a)
        {
            var r = new string[n];
            for (int i = 0; i < n; i++) { var p = Marshal.ReadIntPtr(a, i * IntPtr.Size); r[i] = Marshal.PtrToStringUni(p); Marshal.FreeCoTaskMem(p); }
            if (a != IntPtr.Zero) Marshal.FreeCoTaskMem(a);
            return r;
        }

        public static string UserSelected { get { string s; Marshal.ThrowExceptionForHR(Q().get_UserSelectedProfile(out s)); return s; } }
        // Effective profile: the more restrictive of the user's choice and an active automatic rule
        public static string Active { get { string s; Marshal.ThrowExceptionForHR(Q().get_ActiveProfile(out s)); return s; } }
        public static string QuietMomentProfile { get { string s; Marshal.ThrowExceptionForHR(Q().get_ActiveQuietMomentProfile(out s)); return s; } }
        public static void Set(string id) { Marshal.ThrowExceptionForHR(Q().put_UserSelectedProfile(id)); }
        public static void TurnOffQuietMoment()
        {
            IQuietMomentsManager m; Marshal.ThrowExceptionForHR(Q().get_QuietMomentsManager(out m));
            Marshal.ThrowExceptionForHR(m.TurnOffCurrentlyActiveQuietMoment());
        }
        public static string[] AlwaysAllowedApps() { int n; IntPtr a; Marshal.ThrowExceptionForHR(Q().GetAlwaysAllowedApps(out n, out a)); return Strings(n, a); }
        public static string[] PriorityApps(string profile) { int n; IntPtr a; Marshal.ThrowExceptionForHR(P(profile).GetAllowedApps(out n, out a)); return Strings(n, a); }
        public static void AddPriorityApp(string profile, string aumid) { Marshal.ThrowExceptionForHR(P(profile).AddAllowedApp(aumid)); }
        public static void RemovePriorityApp(string profile, string aumid) { Marshal.ThrowExceptionForHR(P(profile).RemoveAllowedApp(aumid)); }
        // 0 = calls, 1 = phone SMS (requires 0), 2 = reminders (see QuietHoursToastFilterSink::NotificationToastSlotNew)
        public static bool GetFlag(string profile, int i) { int v; Marshal.ThrowExceptionForHR(P(profile).GetSetting(i, out v)); return v != 0; }
    }

    // ---------- Per-app notification settings (NotificationController.dll, hosted by WpnUserService) ----------
    [ComImport, Guid("443b1739-3779-4aba-953b-9e4ff84dd4b6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface INotificationSettings
    {
        [PreserveSig] int GetSettingsForAumid([MarshalAs(UnmanagedType.LPWStr)] string aumid, out IAumidNotificationSettings s);
    }

    [ComImport, Guid("9dca8f00-cb98-434b-9473-5a0691200dc4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAumidNotificationSettings
    {
        [PreserveSig] int get_Aumid([MarshalAs(UnmanagedType.LPWStr)] out string s);
        [PreserveSig] int get_PackageFullName([MarshalAs(UnmanagedType.LPWStr)] out string s);
        [PreserveSig] int get_Enabled(out int v);
        [PreserveSig] int put_Enabled(int v);
        [PreserveSig] int get_ShowBanner(out int v);
        [PreserveSig] int put_ShowBanner(int v);
        [PreserveSig] int get_ShowInActionCenter(out int v);
        [PreserveSig] int put_ShowInActionCenter(int v);
        [PreserveSig] int get_AllowContentAboveLock(out int v);
        [PreserveSig] int put_AllowContentAboveLock(int v);
        [PreserveSig] int get_AllowUrgentNotifications(out int v);
        [PreserveSig] int put_AllowUrgentNotifications(int v);
    }

    public static class AppSettings
    {
        static IAumidNotificationSettings S(string aumid)
        {
            var ns = (INotificationSettings)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("d18705be-fc2f-44c8-aeff-1cd49aea8fc1")));
            IAumidNotificationSettings s; Marshal.ThrowExceptionForHR(ns.GetSettingsForAumid(aumid, out s)); return s;
        }
        public static Hashtable Get(string aumid)
        {
            var s = S(aumid); int v; var h = new Hashtable();
            Marshal.ThrowExceptionForHR(s.get_Enabled(out v)); h["Enabled"] = v != 0;
            Marshal.ThrowExceptionForHR(s.get_ShowBanner(out v)); h["ShowBanner"] = v != 0;
            Marshal.ThrowExceptionForHR(s.get_ShowInActionCenter(out v)); h["ShowInActionCenter"] = v != 0;
            Marshal.ThrowExceptionForHR(s.get_AllowContentAboveLock(out v)); h["AllowContentAboveLock"] = v != 0;
            Marshal.ThrowExceptionForHR(s.get_AllowUrgentNotifications(out v)); h["AllowUrgent"] = v != 0;
            return h;
        }
        public static void Set(string aumid, string name, bool value)
        {
            var s = S(aumid); int v = value ? 1 : 0;
            switch (name)
            {
                case "Enabled": Marshal.ThrowExceptionForHR(s.put_Enabled(v)); break;
                case "ShowBanner": Marshal.ThrowExceptionForHR(s.put_ShowBanner(v)); break;
                case "ShowInActionCenter": Marshal.ThrowExceptionForHR(s.put_ShowInActionCenter(v)); break;
                case "AllowContentAboveLock": Marshal.ThrowExceptionForHR(s.put_AllowContentAboveLock(v)); break;
                case "AllowUrgent": Marshal.ThrowExceptionForHR(s.put_AllowUrgentNotifications(v)); break;
                default: throw new ArgumentException(name);
            }
        }
    }

    // ---------- Toasts (WinRT) ----------
    public class ToastResult
    {
        public string Result;          // Activated | Dismissed | Failed | Timeout
        public string Arguments;       // Activated: arguments of the clicked element
        public Hashtable UserInput;    // Activated: input id -> value
        public string Reason;          // Dismissed: UserCanceled | ApplicationHidden | TimedOut
        public int ErrorCode;          // Failed: HRESULT
    }

    public class ToastWaiter
    {
        readonly ManualResetEvent done = new ManualResetEvent(false);
        readonly ToastResult r = new ToastResult();
        public ToastWaiter(ToastNotification t)
        {
            t.Activated += (s, a) =>
            {
                var e = a as ToastActivatedEventArgs;
                if (e != null)
                {
                    r.Arguments = e.Arguments;
                    r.UserInput = new Hashtable();
                    try { foreach (var kv in e.UserInput) r.UserInput[kv.Key] = Convert.ToString(kv.Value); } catch { }  // UserInput requires Windows 10 2004+
                }
                Finish("Activated");
            };
            t.Dismissed += (s, a) => { r.Reason = a.Reason.ToString(); Finish("Dismissed"); };
            t.Failed += (s, a) => { r.ErrorCode = a.ErrorCode.HResult; Finish("Failed"); };
        }
        void Finish(string kind) { lock (r) { if (r.Result == null) r.Result = kind; } done.Set(); }
        public ToastResult Wait(int timeoutMs)
        {
            if (!done.WaitOne(timeoutMs)) lock (r) { if (r.Result == null) r.Result = "Timeout"; }
            return r;
        }
    }

    public static class Toasts
    {
        static XmlDocument Doc(string xml) { var d = new XmlDocument(); d.LoadXml(xml); return d; }
        static NotificationData Data(IDictionary values, uint seq)
        {
            var d = new NotificationData(); d.SequenceNumber = seq;
            foreach (DictionaryEntry kv in values) d.Values[Convert.ToString(kv.Key)] = Convert.ToString(kv.Value);
            return d;
        }

        public static ToastNotification Create(string xml, string tag, string group, object expiration, bool suppressPopup, bool high, bool expiresOnReboot, IDictionary data)
        {
            var t = new ToastNotification(Doc(xml));
            if (!string.IsNullOrEmpty(tag)) t.Tag = tag;
            if (!string.IsNullOrEmpty(group)) t.Group = group;
            if (expiration != null) t.ExpirationTime = new DateTimeOffset((DateTime)expiration);
            t.SuppressPopup = suppressPopup;
            if (high) t.Priority = ToastNotificationPriority.High;
            t.ExpiresOnReboot = expiresOnReboot;
            if (data != null && data.Count > 0) t.Data = Data(data, 1);
            return t;
        }
        public static ToastWaiter Show(string appId, ToastNotification t, bool attach)
        {
            var w = attach ? new ToastWaiter(t) : null;  // handlers must be attached before Show()
            ToastNotificationManager.CreateToastNotifier(appId).Show(t);
            return w;
        }
        public static void Schedule(string appId, string xml, DateTime at, string tag, string group, bool suppressPopup)
        {
            var s = new ScheduledToastNotification(Doc(xml), new DateTimeOffset(at));
            if (!string.IsNullOrEmpty(tag)) s.Tag = tag;
            if (!string.IsNullOrEmpty(group)) s.Group = group;
            s.SuppressPopup = suppressPopup;
            ToastNotificationManager.CreateToastNotifier(appId).AddToSchedule(s);
        }
        public static string[] Scheduled(string appId)
        {
            var l = new List<string>();
            foreach (var s in ToastNotificationManager.CreateToastNotifier(appId).GetScheduledToastNotifications())
                l.Add(s.Tag + "|" + s.Group + "|" + s.DeliveryTime.LocalDateTime.ToString("o"));
            return l.ToArray();
        }
        public static void Unschedule(string appId, string tag, string group)
        {
            var n = ToastNotificationManager.CreateToastNotifier(appId);
            foreach (var s in n.GetScheduledToastNotifications())
                if ((string.IsNullOrEmpty(tag) || s.Tag == tag) && (string.IsNullOrEmpty(group) || s.Group == group)) n.RemoveFromSchedule(s);
        }
        public static string Update(string appId, string tag, string group, IDictionary values, uint seq)
        {
            var n = ToastNotificationManager.CreateToastNotifier(appId);
            var d = Data(values, seq);
            return (string.IsNullOrEmpty(group) ? n.Update(d, tag) : n.Update(d, tag, group)).ToString();
        }
        public static void Remove(string appId, string tag, string group)
        {
            var h = ToastNotificationManager.History;
            // PowerShell passes $null as "" to string parameters
            if (string.IsNullOrEmpty(group)) h.Clear(appId);
            else if (string.IsNullOrEmpty(tag)) h.RemoveGroup(group, appId);
            else h.Remove(tag, group, appId);
        }
        public static Hashtable[] History(string appId)
        {
            var l = new List<Hashtable>();
            foreach (var t in ToastNotificationManager.History.GetHistory(appId))
            {
                var h = new Hashtable();
                h["Tag"] = t.Tag; h["Group"] = t.Group; h["Xml"] = t.Content.GetXml();
                h["ExpirationTime"] = t.ExpirationTime.HasValue ? (object)t.ExpirationTime.Value.LocalDateTime : null;
                l.Add(h);
            }
            return l.ToArray();
        }
        public static string Setting(string appId) { return ToastNotificationManager.CreateToastNotifier(appId).Setting.ToString(); }
    }
}
