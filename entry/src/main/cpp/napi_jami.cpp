/*
 * NAPI binding of libjami (the Jami daemon) for the HarmonyOS app — the counterpart of the iOS
 * ObjC++ adapters in Ring/Ring/Bridging (DRingAdapter, AccountAdapter, RequestsAdapter,
 * ConversationsAdapter, NameRegistrationAdapter).
 *
 * Scope: accounts, names, contacts, trust requests, conversations, swarm messages, calls and
 * video (camera frames into the daemon, decoded sinks onto XComponent surfaces).
 * Daemon signals arrive on daemon threads; they are marshalled to the ArkTS thread through
 * one thread-safe function and delivered as onEvent(name, payload).
 */
#include <napi/native_api.h>
#include <hilog/log.h>

#include <jami/jami.h>
#include <jami/configurationmanager_interface.h>
#include <jami/conversation_interface.h>
#include <jami/callmanager_interface.h>
#include <jami/videomanager_interface.h>
#include <jami/datatransfer_interface.h>
#include <jami/presencemanager_interface.h>
#include <jami/networkservice_interface.h>

extern "C" {
#include <libavutil/display.h>
#include <libavutil/frame.h>
#include <libswscale/swscale.h>
}

#include <multimedia/image_framework/image/image_native.h>
#include <multimedia/image_framework/image/image_receiver_native.h>
#include <native_buffer/native_buffer.h>
#include <native_window/external_window.h>
#include <sys/mman.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "libjami"

using StrMap = std::map<std::string, std::string>;
using StrVec = std::vector<std::string>;

// ---------------------------------------------------------------------------- ArkTS <-> C++

namespace {

std::string ToStr(napi_env env, napi_value v)
{
    size_t len = 0;
    if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) {
        return {};
    }
    std::string out(len, '\0');
    napi_get_value_string_utf8(env, v, out.data(), len + 1, &len);
    return out;
}

bool ToBool(napi_env env, napi_value v)
{
    bool b = false;
    napi_get_value_bool(env, v, &b);
    return b;
}

int64_t ToInt(napi_env env, napi_value v)
{
    int64_t i = 0;
    napi_get_value_int64(env, v, &i);
    return i;
}

StrMap ToMap(napi_env env, napi_value obj)
{
    StrMap out;
    napi_value keys;
    if (napi_get_property_names(env, obj, &keys) != napi_ok) {
        return out;
    }
    uint32_t n = 0;
    napi_get_array_length(env, keys, &n);
    for (uint32_t i = 0; i < n; i++) {
        napi_value k, v;
        napi_get_element(env, keys, i, &k);
        napi_get_property(env, obj, k, &v);
        out[ToStr(env, k)] = ToStr(env, v);
    }
    return out;
}

std::vector<StrMap> ToMapVec(napi_env env, napi_value arr)
{
    std::vector<StrMap> out;
    uint32_t n = 0;
    napi_get_array_length(env, arr, &n);
    for (uint32_t i = 0; i < n; i++) {
        napi_value item;
        napi_get_element(env, arr, i, &item);
        out.push_back(ToMap(env, item));
    }
    return out;
}

std::vector<uint8_t> ToBytes(napi_env env, napi_value v)
{
    bool isBuf = false;
    napi_is_arraybuffer(env, v, &isBuf);
    if (!isBuf) {
        return {};
    }
    void* data = nullptr;
    size_t len = 0;
    napi_get_arraybuffer_info(env, v, &data, &len);
    auto* p = static_cast<uint8_t*>(data);
    return std::vector<uint8_t>(p, p + len);
}

napi_value Str(napi_env env, const std::string& s)
{
    napi_value v;
    napi_create_string_utf8(env, s.c_str(), s.size(), &v);
    return v;
}

napi_value Bool(napi_env env, bool b)
{
    napi_value v;
    napi_get_boolean(env, b, &v);
    return v;
}

napi_value Num(napi_env env, double d)
{
    napi_value v;
    napi_create_double(env, d, &v);
    return v;
}

napi_value Undef(napi_env env)
{
    napi_value v;
    napi_get_undefined(env, &v);
    return v;
}

napi_value Map(napi_env env, const StrMap& m)
{
    napi_value obj;
    napi_create_object(env, &obj);
    for (const auto& [k, val] : m) {
        napi_set_named_property(env, obj, k.c_str(), Str(env, val));
    }
    return obj;
}

napi_value Vec(napi_env env, const StrVec& vec)
{
    napi_value arr;
    napi_create_array_with_length(env, vec.size(), &arr);
    for (size_t i = 0; i < vec.size(); i++) {
        napi_set_element(env, arr, i, Str(env, vec[i]));
    }
    return arr;
}

napi_value MapVec(napi_env env, const std::vector<StrMap>& vec)
{
    napi_value arr;
    napi_create_array_with_length(env, vec.size(), &arr);
    for (size_t i = 0; i < vec.size(); i++) {
        napi_set_element(env, arr, i, Map(env, vec[i]));
    }
    return arr;
}

napi_value Bytes(napi_env env, const std::vector<uint8_t>& bytes)
{
    void* data = nullptr;
    napi_value buf;
    napi_create_arraybuffer(env, bytes.size(), &data, &buf);
    if (!bytes.empty()) {
        memcpy(data, bytes.data(), bytes.size());
    }
    return buf;
}

napi_value Swarm(napi_env env, const libjami::SwarmMessage& m)
{
    napi_value obj;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "id", Str(env, m.id));
    napi_set_named_property(env, obj, "type", Str(env, m.type));
    napi_set_named_property(env, obj, "linearizedParent", Str(env, m.linearizedParent));
    napi_set_named_property(env, obj, "body", Map(env, m.body));
    napi_set_named_property(env, obj, "reactions", MapVec(env, m.reactions));
    napi_set_named_property(env, obj, "editions", MapVec(env, m.editions));
    napi_value status;
    napi_create_object(env, &status);
    for (const auto& [k, v] : m.status) {
        napi_set_named_property(env, status, k.c_str(), Num(env, v));
    }
    napi_set_named_property(env, obj, "status", status);
    return obj;
}

/** Reads `argc` arguments of the current call. */
std::vector<napi_value> Args(napi_env env, napi_callback_info info, size_t argc)
{
    std::vector<napi_value> argv(argc);
    napi_get_cb_info(env, info, &argc, argv.data(), nullptr, nullptr);
    return argv;
}

// ---------------------------------------------------------------------------- events

/** A daemon signal, captured on the daemon thread and built into ArkTS values on the JS thread. */
struct Event
{
    std::string name;
    std::function<napi_value(napi_env)> payload;
};

napi_threadsafe_function g_events = nullptr;

void CallJs(napi_env env, napi_value jsCb, void*, void* data)
{
    std::unique_ptr<Event> ev(static_cast<Event*>(data));
    if (env == nullptr || jsCb == nullptr) {
        return;
    }
    napi_value argv[2] = {Str(env, ev->name), ev->payload(env)};
    napi_value result;
    napi_call_function(env, Undef(env), jsCb, 2, argv, &result);
}

void Emit(std::string name, std::function<napi_value(napi_env)> payload)
{
    if (g_events == nullptr) {
        return;
    }
    auto* ev = new Event {std::move(name), std::move(payload)};
    if (napi_call_threadsafe_function(g_events, ev, napi_tsfn_nonblocking) != napi_ok) {
        delete ev;
    }
}

/** Builds an object payload from (key, value-builder) pairs. */
using Field = std::pair<const char*, std::function<napi_value(napi_env)>>;
std::function<napi_value(napi_env)> Obj(std::vector<Field> fields)
{
    return [fields = std::move(fields)](napi_env env) {
        napi_value obj;
        napi_create_object(env, &obj);
        for (const auto& [k, f] : fields) {
            napi_set_named_property(env, obj, k, f(env));
        }
        return obj;
    };
}
auto S(std::string s) { return [s = std::move(s)](napi_env env) { return Str(env, s); }; }
auto N(double d) { return [d](napi_env env) { return Num(env, d); }; }
auto B(bool b) { return [b](napi_env env) { return Bool(env, b); }; }
auto M(StrMap m) { return [m = std::move(m)](napi_env env) { return Map(env, m); }; }

void RegisterSignals()
{
    using namespace libjami;
    using std::string;
    std::map<string, std::shared_ptr<CallbackWrapperBase>> handlers;

    handlers.insert(exportable_callback<ConfigurationSignal::AccountsChanged>(
        []() { Emit("AccountsChanged", Obj({})); }));
    handlers.insert(exportable_callback<ConfigurationSignal::AccountDetailsChanged>(
        [](const string& acc, const StrMap& details) {
            Emit("AccountDetailsChanged", Obj({{"accountId", S(acc)}, {"details", M(details)}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::VolatileDetailsChanged>(
        [](const string& acc, const StrMap& details) {
            Emit("VolatileDetailsChanged", Obj({{"accountId", S(acc)}, {"details", M(details)}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::RegistrationStateChanged>(
        [](const string& acc, const string& state, int code, const string& detail) {
            Emit("RegistrationStateChanged",
                 Obj({{"accountId", S(acc)}, {"state", S(state)}, {"code", N(code)}, {"detail", S(detail)}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::IncomingTrustRequest>(
        [](const string& acc, const string& conv, const string& from, const std::vector<uint8_t>& payload,
           time_t received) {
            Emit("IncomingTrustRequest",
                 Obj({{"accountId", S(acc)},
                      {"conversationId", S(conv)},
                      {"from", S(from)},
                      {"payload", [payload](napi_env env) { return Bytes(env, payload); }},
                      {"received", N(static_cast<double>(received))}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::ContactAdded>(
        [](const string& acc, const string& uri, bool confirmed) {
            Emit("ContactAdded", Obj({{"accountId", S(acc)}, {"uri", S(uri)}, {"confirmed", B(confirmed)}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::ContactRemoved>(
        [](const string& acc, const string& uri, bool banned) {
            Emit("ContactRemoved", Obj({{"accountId", S(acc)}, {"uri", S(uri)}, {"banned", B(banned)}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::RegisteredNameFound>(
        [](const string& acc, const string& query, int state, const string& address, const string& name) {
            Emit("RegisteredNameFound",
                 Obj({{"accountId", S(acc)},
                      {"query", S(query)},
                      {"state", N(state)},
                      {"address", S(address)},
                      {"name", S(name)}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::NameRegistrationEnded>(
        [](const string& acc, int state, const string& name) {
            Emit("NameRegistrationEnded", Obj({{"accountId", S(acc)}, {"state", N(state)}, {"name", S(name)}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::AccountMessageStatusChanged>(
        [](const string& acc, const string& conv, const string& peer, const string& msgId, int state) {
            Emit("AccountMessageStatusChanged",
                 Obj({{"accountId", S(acc)},
                      {"conversationId", S(conv)},
                      {"peer", S(peer)},
                      {"messageId", S(msgId)},
                      {"state", N(state)}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::ComposingStatusChanged>(
        [](const string& acc, const string& conv, const string& from, int status) {
            Emit("ComposingStatusChanged",
                 Obj({{"accountId", S(acc)}, {"conversationId", S(conv)}, {"from", S(from)}, {"status", N(status)}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::ProfileReceived>(
        [](const string& acc, const string& from, const string& path) {
            Emit("ProfileReceived", Obj({{"accountId", S(acc)}, {"from", S(from)}, {"path", S(path)}}));
        }));

    handlers.insert(exportable_callback<ConversationSignal::ConversationReady>(
        [](const string& acc, const string& conv) {
            Emit("ConversationReady", Obj({{"accountId", S(acc)}, {"conversationId", S(conv)}}));
        }));
    handlers.insert(exportable_callback<ConversationSignal::ConversationRemoved>(
        [](const string& acc, const string& conv) {
            Emit("ConversationRemoved", Obj({{"accountId", S(acc)}, {"conversationId", S(conv)}}));
        }));
    handlers.insert(exportable_callback<ConversationSignal::ConversationRequestReceived>(
        [](const string& acc, const string& conv, StrMap meta) {
            Emit("ConversationRequestReceived",
                 Obj({{"accountId", S(acc)}, {"conversationId", S(conv)}, {"metadata", M(std::move(meta))}}));
        }));
    handlers.insert(exportable_callback<ConversationSignal::ConversationRequestDeclined>(
        [](const string& acc, const string& conv) {
            Emit("ConversationRequestDeclined", Obj({{"accountId", S(acc)}, {"conversationId", S(conv)}}));
        }));
    handlers.insert(exportable_callback<ConversationSignal::ConversationMemberEvent>(
        [](const string& acc, const string& conv, const string& member, int event) {
            Emit("ConversationMemberEvent",
                 Obj({{"accountId", S(acc)}, {"conversationId", S(conv)}, {"memberUri", S(member)}, {"event", N(event)}}));
        }));
    handlers.insert(exportable_callback<ConversationSignal::ConversationProfileUpdated>(
        [](const string& acc, const string& conv, StrMap profile) {
            Emit("ConversationProfileUpdated",
                 Obj({{"accountId", S(acc)}, {"conversationId", S(conv)}, {"profile", M(std::move(profile))}}));
        }));
    handlers.insert(exportable_callback<ConversationSignal::ConversationPreferencesUpdated>(
        [](const string& acc, const string& conv, StrMap prefs) {
            Emit("ConversationPreferencesUpdated",
                 Obj({{"accountId", S(acc)}, {"conversationId", S(conv)}, {"preferences", M(std::move(prefs))}}));
        }));
    handlers.insert(exportable_callback<ConversationSignal::SwarmLoaded>(
        [](uint32_t id, const string& acc, const string& conv, std::vector<SwarmMessage> messages) {
            Emit("SwarmLoaded",
                 Obj({{"requestId", N(id)},
                      {"accountId", S(acc)},
                      {"conversationId", S(conv)},
                      {"messages", [messages = std::move(messages)](napi_env env) {
                           napi_value arr;
                           napi_create_array_with_length(env, messages.size(), &arr);
                           for (size_t i = 0; i < messages.size(); i++) {
                               napi_set_element(env, arr, i, Swarm(env, messages[i]));
                           }
                           return arr;
                       }}}));
        }));
    handlers.insert(exportable_callback<ConversationSignal::SwarmMessageReceived>(
        [](const string& acc, const string& conv, const SwarmMessage& msg) {
            Emit("SwarmMessageReceived",
                 Obj({{"accountId", S(acc)},
                      {"conversationId", S(conv)},
                      {"message", [msg](napi_env env) { return Swarm(env, msg); }}}));
        }));
    handlers.insert(exportable_callback<ConversationSignal::SwarmMessageUpdated>(
        [](const string& acc, const string& conv, const SwarmMessage& msg) {
            Emit("SwarmMessageUpdated",
                 Obj({{"accountId", S(acc)},
                      {"conversationId", S(conv)},
                      {"message", [msg](napi_env env) { return Swarm(env, msg); }}}));
        }));

    handlers.insert(exportable_callback<ConversationSignal::ReactionAdded>(
        [](const string& acc, const string& conv, const string& messageId, StrMap reaction) {
            Emit("ReactionAdded", Obj({{"accountId", S(acc)},
                                       {"conversationId", S(conv)},
                                       {"messageId", S(messageId)},
                                       {"reaction", M(reaction)}}));
        }));
    // Collaborative documents (conversation_interface.h). iOS: CollaborationAdapter.mm.
    handlers.insert(exportable_callback<ConversationSignal::CollaborativeDocumentUpdate>(
        [](const string& acc, const string& conv, const string& doc, const std::vector<uint8_t>& update) {
            Emit("CollaborativeDocumentUpdate",
                 Obj({{"accountId", S(acc)}, {"conversationId", S(conv)}, {"documentId", S(doc)},
                      {"update", [update](napi_env env) { return Bytes(env, update); }}}));
        }));
    handlers.insert(exportable_callback<ConversationSignal::CollaborativeAwarenessChanged>(
        [](const string& acc, const string& conv, const string& doc, const string& peer, uint64_t client,
           const string& state) {
            Emit("CollaborativeAwarenessChanged",
                 Obj({{"accountId", S(acc)}, {"conversationId", S(conv)}, {"documentId", S(doc)},
                      {"peerId", S(peer)}, {"clientId", N(static_cast<double>(client))}, {"state", S(state)}}));
        }));
    handlers.insert(exportable_callback<ConversationSignal::CollaborativeParticipantLeft>(
        [](const string& acc, const string& conv, const string& doc, const string& peer, uint64_t client) {
            Emit("CollaborativeParticipantLeft",
                 Obj({{"accountId", S(acc)}, {"conversationId", S(conv)}, {"documentId", S(doc)},
                      {"peerId", S(peer)}, {"clientId", N(static_cast<double>(client))}}));
        }));
    handlers.insert(exportable_callback<ConversationSignal::CollaborativeDocumentRenamed>(
        [](const string& acc, const string& conv, const string& doc, const string& name) {
            Emit("CollaborativeDocumentRenamed",
                 Obj({{"accountId", S(acc)}, {"conversationId", S(conv)}, {"documentId", S(doc)}, {"name", S(name)}}));
        }));
    handlers.insert(exportable_callback<ConversationSignal::CollaborativeDocumentRemoved>(
        [](const string& acc, const string& conv, const string& doc, bool everywhere) {
            Emit("CollaborativeDocumentRemoved",
                 Obj({{"accountId", S(acc)}, {"conversationId", S(conv)}, {"documentId", S(doc)},
                      {"everywhere", B(everywhere)}}));
        }));
    handlers.insert(exportable_callback<ConversationSignal::CollaborativeAttachmentAdded>(
        [](const string& acc, const string& conv, const string& doc, const string& attachment) {
            Emit("CollaborativeAttachmentAdded",
                 Obj({{"accountId", S(acc)}, {"conversationId", S(conv)}, {"documentId", S(doc)},
                      {"attachmentId", S(attachment)}}));
        }));
    // T-1634: a document's download finished (or none was needed); conv is the parent conversation.
    handlers.insert(exportable_callback<ConversationSignal::CollaborativeDocumentReplicated>(
        [](const string& acc, const string& conv, const string& doc, bool stored) {
            Emit("CollaborativeDocumentReplicated",
                 Obj({{"accountId", S(acc)}, {"conversationId", S(conv)}, {"documentId", S(doc)},
                      {"stored", B(stored)}}));
        }));
    handlers.insert(exportable_callback<ConversationSignal::ReactionRemoved>(
        [](const string& acc, const string& conv, const string& messageId, const string& reactionId) {
            Emit("ReactionRemoved", Obj({{"accountId", S(acc)},
                                         {"conversationId", S(conv)},
                                         {"messageId", S(messageId)},
                                         {"reactionId", S(reactionId)}}));
        }));
    handlers.insert(exportable_callback<CallSignal::IncomingCall>(
        [](const string& acc, const string& callId, const string& from, const std::vector<StrMap>& media) {
            Emit("IncomingCall",
                 Obj({{"accountId", S(acc)},
                      {"callId", S(callId)},
                      {"from", S(from)},
                      {"mediaList", [media](napi_env env) { return MapVec(env, media); }}}));
        }));
    handlers.insert(exportable_callback<CallSignal::StateChange>(
        [](const string& acc, const string& callId, const string& state, int code) {
            Emit("CallStateChanged",
                 Obj({{"accountId", S(acc)}, {"callId", S(callId)}, {"state", S(state)}, {"code", N(code)}}));
        }));
    handlers.insert(exportable_callback<CallSignal::MediaNegotiationStatus>(
        [](const string& callId, const string& event, const std::vector<StrMap>& media) {
            Emit("MediaNegotiationStatus",
                 Obj({{"callId", S(callId)},
                      {"event", S(event)},
                      {"mediaList", [media](napi_env env) { return MapVec(env, media); }}}));
        }));
    handlers.insert(exportable_callback<CallSignal::MediaChangeRequested>(
        [](const string& acc, const string& callId, const std::vector<StrMap>& media) {
            Emit("MediaChangeRequested",
                 Obj({{"accountId", S(acc)},
                      {"callId", S(callId)},
                      {"mediaList", [media](napi_env env) { return MapVec(env, media); }}}));
        }));
    handlers.insert(exportable_callback<CallSignal::PeerHold>(
        [](const string& callId, bool hold) { Emit("PeerHold", Obj({{"callId", S(callId)}, {"hold", B(hold)}})); }));
    handlers.insert(exportable_callback<CallSignal::AudioMuted>(
        [](const string& callId, bool muted) { Emit("AudioMuted", Obj({{"callId", S(callId)}, {"muted", B(muted)}})); }));
    handlers.insert(exportable_callback<CallSignal::VideoMuted>(
        [](const string& callId, bool muted) { Emit("VideoMuted", Obj({{"callId", S(callId)}, {"muted", B(muted)}})); }));

    handlers.insert(exportable_callback<CallSignal::ConferenceCreated>(
        [](const string& acc, const string& conv, const string& confId) {
            Emit("ConferenceCreated", Obj({{"accountId", S(acc)}, {"conversationId", S(conv)}, {"confId", S(confId)}}));
        }));
    handlers.insert(exportable_callback<CallSignal::ConferenceChanged>(
        [](const string& acc, const string& confId, const string& state) {
            Emit("ConferenceChanged", Obj({{"accountId", S(acc)}, {"confId", S(confId)}, {"state", S(state)}}));
        }));
    handlers.insert(exportable_callback<CallSignal::ConferenceRemoved>(
        [](const string& acc, const string& confId) {
            Emit("ConferenceRemoved", Obj({{"accountId", S(acc)}, {"confId", S(confId)}}));
        }));
    handlers.insert(exportable_callback<CallSignal::OnConferenceInfosUpdated>(
        [](const string& confId, const std::vector<StrMap>& infos) {
            Emit("OnConferenceInfosUpdated",
                 Obj({{"confId", S(confId)}, {"infos", [infos](napi_env env) { return MapVec(env, infos); }}}));
        }));
    handlers.insert(exportable_callback<CallSignal::RemoteRecordingChanged>(
        [](const string& callId, const string& peer, bool state) {
            Emit("RemoteRecordingChanged", Obj({{"callId", S(callId)}, {"peer", S(peer)}, {"state", B(state)}}));
        }));
    handlers.insert(exportable_callback<CallSignal::IncomingMessage>(
        [](const string& acc, const string& callId, const string& from, const StrMap& msg) {
            Emit("CallIncomingMessage",
                 Obj({{"accountId", S(acc)}, {"callId", S(callId)}, {"from", S(from)}, {"message", M(msg)}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::ActiveCallsChanged>(
        [](const string& acc, const string& conv, const std::vector<StrMap>& calls) {
            Emit("ActiveCallsChanged", Obj({{"accountId", S(acc)},
                                            {"conversationId", S(conv)},
                                            {"activeCalls", [calls](napi_env env) { return MapVec(env, calls); }}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::KnownDevicesChanged>(
        [](const string& acc, const StrMap& devices) {
            Emit("KnownDevicesChanged", Obj({{"accountId", S(acc)}, {"devices", M(devices)}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::DeviceRevocationEnded>(
        [](const string& acc, const string& device, int status) {
            Emit("DeviceRevocationEnded", Obj({{"accountId", S(acc)}, {"device", S(device)}, {"status", N(status)}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::AddDeviceStateChanged>(
        [](const string& acc, uint32_t opId, int state, const StrMap& detail) {
            Emit("AddDeviceStateChanged",
                 Obj({{"accountId", S(acc)}, {"opId", N(opId)}, {"state", N(state)}, {"detail", M(detail)}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::DeviceAuthStateChanged>(
        [](const string& acc, int state, const StrMap& detail) {
            Emit("DeviceAuthStateChanged", Obj({{"accountId", S(acc)}, {"state", N(state)}, {"detail", M(detail)}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::UserSearchEnded>(
        [](const string& acc, int state, const string& query, const std::vector<StrMap>& results) {
            Emit("UserSearchEnded", Obj({{"accountId", S(acc)},
                                         {"state", N(state)},
                                         {"query", S(query)},
                                         {"results", [results](napi_env env) { return MapVec(env, results); }}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::IncomingAccountMessage>(
        [](const string& acc, const string& from, const string& messageId, const StrMap& payloads) {
            Emit("IncomingAccountMessage",
                 Obj({{"accountId", S(acc)}, {"from", S(from)}, {"messageId", S(messageId)}, {"payloads", M(payloads)}}));
        }));
    handlers.insert(exportable_callback<ServiceSignal::PeerServicesReceived>(
        [](uint32_t requestId, const string& acc, const string& peer, int status, const string& json) {
            Emit("PeerServicesReceived", Obj({{"requestId", N(requestId)},
                                              {"accountId", S(acc)},
                                              {"peerId", S(peer)},
                                              {"status", N(status)},
                                              {"servicesJson", S(json)}}));
        }));
    handlers.insert(exportable_callback<ServiceSignal::TunnelOpened>(
        [](const string& acc, const string& tunnelId, uint16_t port) {
            Emit("ServiceTunnelOpened", Obj({{"accountId", S(acc)}, {"tunnelId", S(tunnelId)}, {"localPort", N(port)}}));
        }));
    handlers.insert(exportable_callback<ServiceSignal::TunnelClosed>(
        [](const string& acc, const string& tunnelId, const string& reason) {
            Emit("ServiceTunnelClosed", Obj({{"accountId", S(acc)}, {"tunnelId", S(tunnelId)}, {"reason", S(reason)}}));
        }));
    handlers.insert(exportable_callback<ConfigurationSignal::MessageSend>(
        [](const string& line) { Emit("MessageSend", Obj({{"message", S(line)}})); }));
    handlers.insert(exportable_callback<PresenceSignal::NewBuddyNotification>(
        [](const string& acc, const string& uri, int status, const string& line) {
            Emit("NewBuddyNotification", Obj({{"accountId", S(acc)}, {"uri", S(uri)}, {"status", N(status)}, {"lineStatus", S(line)}}));
        }));
    handlers.insert(exportable_callback<DataTransferSignal::DataTransferEvent>(
        [](const string& acc, const string& conv, const string& interaction, const string& fileId, int code) {
            Emit("DataTransferEvent", Obj({{"accountId", S(acc)},
                                           {"conversationId", S(conv)},
                                           {"interactionId", S(interaction)},
                                           {"fileId", S(fileId)},
                                           {"eventCode", N(code)}}));
        }));

    handlers.insert(exportable_callback<VideoSignal::DecodingStarted>(
        [](const string& sinkId, const string&, int w, int h, bool isMixer) {
            Emit("DecodingStarted", Obj({{"sinkId", S(sinkId)}, {"width", N(w)}, {"height", N(h)}, {"isMixer", B(isMixer)}}));
        }));
    handlers.insert(exportable_callback<VideoSignal::DecodingStopped>(
        [](const string& sinkId, const string&, bool isMixer) {
            Emit("DecodingStopped", Obj({{"sinkId", S(sinkId)}, {"isMixer", B(isMixer)}}));
        }));
    handlers.insert(exportable_callback<VideoSignal::StartCapture>(
        [](const string& device) { Emit("StartCapture", Obj({{"device", S(device)}})); }));
    handlers.insert(exportable_callback<VideoSignal::StopCapture>(
        [](const string& device) { Emit("StopCapture", Obj({{"device", S(device)}})); }));

    registerSignalHandlers(handlers);
}

/** The daemon logs to stdout/stderr; nothing reads those on HarmonyOS, so pipe them to hilog. */
void RedirectStdioToHilog()
{
    static bool done = false;
    if (done) {
        return;
    }
    done = true;
    int fds[2];
    if (pipe(fds) != 0) {
        return;
    }
    setvbuf(stdout, nullptr, _IOLBF, 0);
    setvbuf(stderr, nullptr, _IONBF, 0);
    dup2(fds[1], STDOUT_FILENO);
    dup2(fds[1], STDERR_FILENO);
    std::thread([fd = fds[0]]() {
        std::string line;
        char buf[1024];
        ssize_t n;
        while ((n = read(fd, buf, sizeof(buf))) > 0) {
            for (ssize_t i = 0; i < n; i++) {
                if (buf[i] == '\n') {
                    OH_LOG_INFO(LOG_APP, "%{public}s", line.c_str());
                    line.clear();
                } else {
                    line.push_back(buf[i]);
                }
            }
        }
    }).detach();
}

// ---------------------------------------------------------------------------- serial worker

/**
 * A daemon call run off the JS thread, and the promise it settles back on it. T-1625: a SIP
 * account write re-registers the account and resolves its host, and on the phone each failed
 * lookup blocks the caller for up to a second.
 */
struct Job
{
    std::function<void()> run;
    napi_deferred deferred {nullptr};
    std::string error;
};

napi_threadsafe_function g_settle = nullptr;
std::mutex g_jobsMutex;
std::condition_variable g_jobsCv;
std::deque<Job*> g_jobs;

void SettleJs(napi_env env, napi_value, void*, void* data)
{
    std::unique_ptr<Job> job(static_cast<Job*>(data));
    if (env == nullptr) {
        return;
    }
    if (job->error.empty()) {
        napi_resolve_deferred(env, job->deferred, Undef(env));
        return;
    }
    napi_value err;
    napi_create_error(env, nullptr, Str(env, job->error), &err);
    napi_reject_deferred(env, job->deferred, err);
}

/**
 * The one worker thread: jobs run one at a time in queue order, so two writes never swap, which
 * napi_async_work on the libuv pool could do. libjami takes calls from any thread - its signals
 * already come from daemon threads, and its pjsip registers an unknown thread on first use.
 */
void RunJobs()
{
    for (;;) {
        Job* job;
        {
            std::unique_lock lock(g_jobsMutex);
            g_jobsCv.wait(lock, [] { return !g_jobs.empty(); });
            job = g_jobs.front();
            g_jobs.pop_front();
        }
        // Unparsable values (a port of "abc") throw from the daemon; off the JS thread an
        // uncaught throw would end the app.
        try {
            job->run();
        } catch (const std::exception& e) {
            job->error = std::string("libjami: ") + e.what();
        } catch (...) {
            job->error = "libjami: unknown error";
        }
        if (napi_call_threadsafe_function(g_settle, job, napi_tsfn_nonblocking) != napi_ok) {
            delete job;
        }
    }
}

/** Queues `run` on the worker; the returned promise settles on the JS thread once it has run. */
napi_value RunSerial(napi_env env, std::function<void()> run)
{
    static std::once_flag once;
    std::call_once(once, [env]() {
        napi_create_threadsafe_function(env, nullptr, nullptr, Str(env, "jamiSerial"), 0, 1, nullptr, nullptr,
                                        nullptr, SettleJs, &g_settle);
        std::thread(RunJobs).detach();
    });
    auto* job = new Job {std::move(run)};
    napi_value promise;
    napi_create_promise(env, &job->deferred, &promise);
    {
        std::lock_guard lock(g_jobsMutex);
        g_jobs.push_back(job);
    }
    g_jobsCv.notify_one();
    return promise;
}

// ---------------------------------------------------------------------------- exported calls

/** init(dataDir: string, onEvent: (name, payload) => void): boolean */
napi_value Init(napi_env env, napi_callback_info info)
{
    static std::once_flag once;
    static bool ok = false;
    auto argv = Args(env, info, 2);
    std::string dir = ToStr(env, argv[0]);
    napi_value cb = argv[1];
    std::call_once(once, [&]() {
        RedirectStdioToHilog();
        // On Linux the daemon resolves its files from HOME/XDG; point them at the app sandbox.
        setenv("HOME", dir.c_str(), 1);
        setenv("XDG_DATA_HOME", (dir + "/data").c_str(), 1);
        setenv("XDG_CONFIG_HOME", (dir + "/config").c_str(), 1);
        setenv("XDG_CACHE_HOME", (dir + "/cache").c_str(), 1);
        // OpenDHT's HTTPS client (name server, DHT proxy) needs the CA store; HarmonyOS keeps
        // the system roots, OpenSSL-hashed, here.
        setenv("CA_ROOT_PATH", "/etc/security/certificates", 0);
        napi_value name = Str(env, "jamiEvents");
        napi_create_threadsafe_function(env, cb, nullptr, name, 0, 1, nullptr, nullptr, nullptr, CallJs, &g_events);
        RegisterSignals();
        // No NO_LOCAL_* flag: the daemon's VideoManager also owns the audio inputs, and
        // without it a call's audio sender has no microphone input.
        auto flags = static_cast<libjami::InitFlag>(libjami::LIBJAMI_FLAG_CONSOLE_LOG);
        ok = libjami::init(flags) && libjami::start();
        OH_LOG_INFO(LOG_APP, "libjami %{public}s started=%{public}d", libjami::version(), ok);
    });
    return Bool(env, ok);
}

#define FN(name) napi_value name(napi_env env, napi_callback_info info)

FN(Version) { return Str(env, libjami::version()); }
FN(ConnectivityChanged) { libjami::connectivityChanged(); return Undef(env); }

FN(GetAccountList) { return Vec(env, libjami::getAccountList()); }
FN(GetAccountDetails) { auto a = Args(env, info, 1); return Map(env, libjami::getAccountDetails(ToStr(env, a[0]))); }
FN(GetVolatileAccountDetails)
{
    auto a = Args(env, info, 1);
    return Map(env, libjami::getVolatileAccountDetails(ToStr(env, a[0])));
}
FN(GetAccountTemplate) { auto a = Args(env, info, 1); return Map(env, libjami::getAccountTemplate(ToStr(env, a[0]))); }
FN(AddAccount) { auto a = Args(env, info, 1); return Str(env, libjami::addAccount(ToMap(env, a[0]))); }
/** setAccountDetails(accountId, details): Promise<void>, on the serial worker (T-1625). */
FN(SetAccountDetails)
{
    auto a = Args(env, info, 2);
    return RunSerial(env, [id = ToStr(env, a[0]), details = ToMap(env, a[1])]() {
        libjami::setAccountDetails(id, details);
    });
}
/**
 * setAccountActive(accountId, active): Promise<void> - it (un)registers too, so same queue (T-1627).
 * shutdownConnections=true, as iOS AccountAdapter.mm: a deactivated (backgrounded, then frozen) account
 * must not keep its peer channels, or after resume messages are written to dead ones (T-1044).
 */
FN(SetAccountActive)
{
    auto a = Args(env, info, 2);
    return RunSerial(env, [id = ToStr(env, a[0]), active = ToBool(env, a[1])]() {
        libjami::setAccountActive(id, active, true);
    });
}
FN(RemoveAccount) { auto a = Args(env, info, 1); libjami::removeAccount(ToStr(env, a[0])); return Undef(env); }

FN(LookupName)
{
    auto a = Args(env, info, 3);
    return Bool(env, libjami::lookupName(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2])));
}
FN(LookupAddress)
{
    auto a = Args(env, info, 3);
    return Bool(env, libjami::lookupAddress(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2])));
}
FN(RegisterName)
{
    auto a = Args(env, info, 4);
    return Bool(env, libjami::registerName(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3])));
}

FN(SendTrustRequest)
{
    auto a = Args(env, info, 3);
    libjami::sendTrustRequest(ToStr(env, a[0]), ToStr(env, a[1]), ToBytes(env, a[2]));
    return Undef(env);
}
FN(AcceptTrustRequest)
{
    auto a = Args(env, info, 2);
    return Bool(env, libjami::acceptTrustRequest(ToStr(env, a[0]), ToStr(env, a[1])));
}
FN(DiscardTrustRequest)
{
    auto a = Args(env, info, 2);
    return Bool(env, libjami::discardTrustRequest(ToStr(env, a[0]), ToStr(env, a[1])));
}
FN(GetTrustRequests) { auto a = Args(env, info, 1); return MapVec(env, libjami::getTrustRequests(ToStr(env, a[0]))); }
FN(AddContact)
{
    auto a = Args(env, info, 2);
    libjami::addContact(ToStr(env, a[0]), ToStr(env, a[1]));
    return Undef(env);
}
FN(RemoveContact)
{
    auto a = Args(env, info, 3);
    libjami::removeContact(ToStr(env, a[0]), ToStr(env, a[1]), ToBool(env, a[2]));
    return Undef(env);
}
FN(GetContactDetails)
{
    auto a = Args(env, info, 2);
    return Map(env, libjami::getContactDetails(ToStr(env, a[0]), ToStr(env, a[1])));
}
FN(GetContacts) { auto a = Args(env, info, 1); return MapVec(env, libjami::getContacts(ToStr(env, a[0]))); }

FN(GetConversations) { auto a = Args(env, info, 1); return Vec(env, libjami::getConversations(ToStr(env, a[0]))); }
FN(GetConversationRequests)
{
    auto a = Args(env, info, 1);
    return MapVec(env, libjami::getConversationRequests(ToStr(env, a[0])));
}
FN(StartConversation) { auto a = Args(env, info, 1); return Str(env, libjami::startConversation(ToStr(env, a[0]))); }
FN(AcceptConversationRequest)
{
    auto a = Args(env, info, 2);
    libjami::acceptConversationRequest(ToStr(env, a[0]), ToStr(env, a[1]));
    return Undef(env);
}
FN(DeclineConversationRequest)
{
    auto a = Args(env, info, 2);
    libjami::declineConversationRequest(ToStr(env, a[0]), ToStr(env, a[1]));
    return Undef(env);
}
FN(RemoveConversation)
{
    auto a = Args(env, info, 2);
    return Bool(env, libjami::removeConversation(ToStr(env, a[0]), ToStr(env, a[1])));
}
FN(ConversationInfos)
{
    auto a = Args(env, info, 2);
    return Map(env, libjami::conversationInfos(ToStr(env, a[0]), ToStr(env, a[1])));
}
FN(GetConversationMembers)
{
    auto a = Args(env, info, 2);
    return MapVec(env, libjami::getConversationMembers(ToStr(env, a[0]), ToStr(env, a[1])));
}
FN(AddConversationMember)
{
    auto a = Args(env, info, 3);
    libjami::addConversationMember(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]));
    return Undef(env);
}
FN(SendMessage)
{
    auto a = Args(env, info, 5);
    libjami::sendMessage(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3]),
                         static_cast<int32_t>(ToInt(env, a[4])));
    return Undef(env);
}
FN(LoadConversation)
{
    auto a = Args(env, info, 4);
    return Num(env, libjami::loadConversation(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]),
                                              static_cast<size_t>(ToInt(env, a[3]))));
}
FN(ClearCache)
{
    auto a = Args(env, info, 2);
    libjami::clearCache(ToStr(env, a[0]), ToStr(env, a[1]));
    return Undef(env);
}
FN(SetMessageDisplayed)
{
    auto a = Args(env, info, 4);
    return Bool(env, libjami::setMessageDisplayed(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]),
                                                  static_cast<int>(ToInt(env, a[3]))));
}
FN(PlaceCallWithMedia)
{
    auto a = Args(env, info, 3);
    return Str(env, libjami::placeCallWithMedia(ToStr(env, a[0]), ToStr(env, a[1]), ToMapVec(env, a[2])));
}
FN(AcceptWithMedia)
{
    auto a = Args(env, info, 3);
    return Bool(env, libjami::acceptWithMedia(ToStr(env, a[0]), ToStr(env, a[1]), ToMapVec(env, a[2])));
}
FN(Refuse) { auto a = Args(env, info, 2); return Bool(env, libjami::refuse(ToStr(env, a[0]), ToStr(env, a[1]))); }
FN(HangUp) { auto a = Args(env, info, 2); return Bool(env, libjami::hangUp(ToStr(env, a[0]), ToStr(env, a[1]))); }
FN(Hold) { auto a = Args(env, info, 2); return Bool(env, libjami::hold(ToStr(env, a[0]), ToStr(env, a[1]))); }
FN(Resume) { auto a = Args(env, info, 2); return Bool(env, libjami::resume(ToStr(env, a[0]), ToStr(env, a[1]))); }
FN(MuteLocalMedia)
{
    auto a = Args(env, info, 4);
    return Bool(env, libjami::muteLocalMedia(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToBool(env, a[3])));
}
FN(GetCallDetails)
{
    auto a = Args(env, info, 2);
    return Map(env, libjami::getCallDetails(ToStr(env, a[0]), ToStr(env, a[1])));
}
FN(GetCallList) { auto a = Args(env, info, 1); return Vec(env, libjami::getCallList(ToStr(env, a[0]))); }
FN(AnswerMediaChangeRequest)
{
    auto a = Args(env, info, 3);
    return Bool(env, libjami::answerMediaChangeRequest(ToStr(env, a[0]), ToStr(env, a[1]), ToMapVec(env, a[2])));
}
FN(RequestMediaChange)
{
    auto a = Args(env, info, 3);
    return Bool(env, libjami::requestMediaChange(ToStr(env, a[0]), ToStr(env, a[1]), ToMapVec(env, a[2])));
}
FN(CurrentMediaList)
{
    auto a = Args(env, info, 2);
    return MapVec(env, libjami::currentMediaList(ToStr(env, a[0]), ToStr(env, a[1])));
}
FN(SetAudioOutputDevice)
{
    auto a = Args(env, info, 1);
    libjami::setAudioOutputDevice(static_cast<int32_t>(ToInt(env, a[0])));
    return Undef(env);
}
FN(PlayDTMF) { auto a = Args(env, info, 1); libjami::playDTMF(ToStr(env, a[0])); return Undef(env); }

FN(CountInteractions)
{
    auto a = Args(env, info, 5);
    return Num(env, libjami::countInteractions(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]),
                                               ToStr(env, a[3]), ToStr(env, a[4])));
}
FN(GetConversationPreferences)
{
    auto a = Args(env, info, 2);
    return Map(env, libjami::getConversationPreferences(ToStr(env, a[0]), ToStr(env, a[1])));
}
FN(SetIsComposing)
{
    auto a = Args(env, info, 3);
    libjami::setIsComposing(ToStr(env, a[0]), ToStr(env, a[1]), ToBool(env, a[2]));
    return Undef(env);
}

// ---------------------------------------------------------------------------- conversations, transfers

// Collaborative documents: (accountId, conversationId[, documentId, ...]). iOS: CollaborationAdapter.mm.
FN(CreateCollaborativeDocument)
{
    auto a = Args(env, info, 4);
    return Str(env, libjami::createCollaborativeDocument(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]),
                                                         ToStr(env, a[3])));
}
FN(OpenCollaborativeDocument)
{
    auto a = Args(env, info, 3);
    return Bytes(env, libjami::openCollaborativeDocument(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2])));
}
FN(CloseCollaborativeDocument)
{
    auto a = Args(env, info, 3);
    libjami::closeCollaborativeDocument(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]));
    return Undef(env);
}
FN(RemoveCollaborativeDocument)
{
    auto a = Args(env, info, 3);
    return Bool(env, libjami::removeCollaborativeDocument(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2])));
}
FN(RemoveCollaborativeDocumentLocally)
{
    auto a = Args(env, info, 3);
    return Bool(env,
                libjami::removeCollaborativeDocumentLocally(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2])));
}
FN(ApplyCollaborativeUpdate)
{
    auto a = Args(env, info, 4);
    libjami::applyCollaborativeUpdate(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToBytes(env, a[3]));
    return Undef(env);
}
FN(CollaborativeDocumentState)
{
    auto a = Args(env, info, 3);
    return Bytes(env, libjami::collaborativeDocumentState(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2])));
}
FN(CollaborativeDocumentStateAt)
{
    auto a = Args(env, info, 4);
    return Bytes(env, libjami::collaborativeDocumentStateAt(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]),
                                                            ToStr(env, a[3])));
}
FN(SetCollaborativeAwareness)
{
    auto a = Args(env, info, 4);
    libjami::setCollaborativeAwareness(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3]));
    return Undef(env);
}
FN(SetCollaborativeDocumentName)
{
    auto a = Args(env, info, 4);
    libjami::setCollaborativeDocumentName(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3]));
    return Undef(env);
}
FN(CollaborativeDocumentName)
{
    auto a = Args(env, info, 3);
    return Str(env, libjami::collaborativeDocumentName(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2])));
}
FN(GetCollaborativeDocuments)
{
    auto a = Args(env, info, 2);
    return MapVec(env, libjami::getCollaborativeDocuments(ToStr(env, a[0]), ToStr(env, a[1])));
}
FN(GetCollaborativeDocumentHistory)
{
    auto a = Args(env, info, 4);
    return MapVec(env, libjami::getCollaborativeDocumentHistory(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]),
                                                                static_cast<uint32_t>(ToInt(env, a[3]))));
}
FN(AddCollaborativeAttachment)
{
    auto a = Args(env, info, 4);
    return Str(env, libjami::addCollaborativeAttachment(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]),
                                                        ToBytes(env, a[3])));
}
FN(CollaborativeAttachment)
{
    auto a = Args(env, info, 4);
    return Bytes(env, libjami::collaborativeAttachment(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]),
                                                       ToStr(env, a[3])));
}

FN(UpdateConversationInfos)
{
    auto a = Args(env, info, 3);
    libjami::updateConversationInfos(ToStr(env, a[0]), ToStr(env, a[1]), ToMap(env, a[2]));
    return Undef(env);
}
FN(SetConversationPreferences)
{
    auto a = Args(env, info, 3);
    libjami::setConversationPreferences(ToStr(env, a[0]), ToStr(env, a[1]), ToMap(env, a[2]));
    return Undef(env);
}
FN(RemoveConversationMember)
{
    auto a = Args(env, info, 3);
    libjami::removeConversationMember(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]));
    return Undef(env);
}
FN(LoadConversationUntil)
{
    auto a = Args(env, info, 4);
    return Num(env, libjami::loadSwarmUntil(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3])));
}
FN(SendAccountTextMessage)
{
    auto a = Args(env, info, 4);
    return Num(env, static_cast<double>(libjami::sendAccountTextMessage(ToStr(env, a[0]), ToStr(env, a[1]),
                                                                        ToMap(env, a[2]), static_cast<int32_t>(ToInt(env, a[3])))));
}
FN(SendFile)
{
    auto a = Args(env, info, 5);
    libjami::sendFile(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3]), ToStr(env, a[4]));
    return Undef(env);
}
FN(DownloadFile)
{
    auto a = Args(env, info, 5);
    return Bool(env, libjami::downloadFile(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3]), ToStr(env, a[4])));
}
FN(CancelDataTransfer)
{
    auto a = Args(env, info, 3);
    return Num(env, static_cast<int>(libjami::cancelDataTransfer(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]))));
}
/** fileTransferInfo(accountId, conversationId, fileId): {code, path, total, progress} */
FN(FileTransferInfo)
{
    auto a = Args(env, info, 3);
    std::string path;
    int64_t total = 0, progress = 0;
    auto code = libjami::fileTransferInfo(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), path, total, progress);
    return Obj({{"code", N(static_cast<int>(code))},
                {"path", S(path)},
                {"total", N(static_cast<double>(total))},
                {"progress", N(static_cast<double>(progress))}})(env);
}

// ---------------------------------------------------------------------------- presence, profile, accounts

FN(SubscribeBuddy)
{
    auto a = Args(env, info, 3);
    libjami::subscribeBuddy(ToStr(env, a[0]), ToStr(env, a[1]), ToBool(env, a[2]));
    return Undef(env);
}
FN(PublishPresence)
{
    auto a = Args(env, info, 3);
    libjami::publish(ToStr(env, a[0]), ToBool(env, a[1]), ToStr(env, a[2]));
    return Undef(env);
}
/** updateProfile(accountId, displayName, avatar(path or base64), fileType, flag) */
FN(UpdateProfile)
{
    auto a = Args(env, info, 5);
    libjami::updateProfile(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3]), "",
                           static_cast<int32_t>(ToInt(env, a[4])));
    return Undef(env);
}
FN(GetCredentials) { auto a = Args(env, info, 1); return MapVec(env, libjami::getCredentials(ToStr(env, a[0]))); }
/** setCredentials(accountId, credentials): Promise<void> - it re-registers too, so same queue. */
FN(SetCredentials)
{
    auto a = Args(env, info, 2);
    return RunSerial(env, [id = ToStr(env, a[0]), creds = ToMapVec(env, a[1])]() {
        libjami::setCredentials(id, creds);
    });
}
/** sendRegister(accountId, enable): Promise<void> - it (un)registers too, so same queue (T-1627). */
FN(SendRegister)
{
    auto a = Args(env, info, 2);
    return RunSerial(env, [id = ToStr(env, a[0]), enable = ToBool(env, a[1])]() {
        libjami::sendRegister(id, enable);
    });
}
FN(QueryPeerServices)
{
    auto a = Args(env, info, 2);
    return Num(env, libjami::queryPeerServices(ToStr(env, a[0]), ToStr(env, a[1])));
}
FN(OpenServiceTunnel)
{
    auto a = Args(env, info, 6);
    return Str(env, libjami::openServiceTunnel(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3]),
                                               ToStr(env, a[4]), static_cast<uint16_t>(ToInt(env, a[5]))));
}
FN(CloseServiceTunnel)
{
    auto a = Args(env, info, 2);
    return Bool(env, libjami::closeServiceTunnel(ToStr(env, a[0]), ToStr(env, a[1])));
}
FN(Monitor) { auto a = Args(env, info, 1); libjami::monitor(ToBool(env, a[0])); return Undef(env); }
FN(SearchUser) { auto a = Args(env, info, 2); return Bool(env, libjami::searchUser(ToStr(env, a[0]), ToStr(env, a[1]))); }
FN(ChangeAccountPassword)
{
    auto a = Args(env, info, 3);
    return Bool(env, libjami::changeAccountPassword(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2])));
}
FN(IsPasswordValid) { auto a = Args(env, info, 2); return Bool(env, libjami::isPasswordValid(ToStr(env, a[0]), ToStr(env, a[1]))); }
FN(ExportToFile)
{
    auto a = Args(env, info, 4);
    return Bool(env, libjami::exportToFile(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3])));
}
FN(RevokeDevice)
{
    auto a = Args(env, info, 4);
    return Bool(env, libjami::revokeDevice(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3])));
}
FN(GetKnownRingDevices) { auto a = Args(env, info, 1); return Map(env, libjami::getKnownRingDevices(ToStr(env, a[0]))); }
FN(AddDevice) { auto a = Args(env, info, 2); return Num(env, libjami::addDevice(ToStr(env, a[0]), ToStr(env, a[1]))); }
FN(ConfirmAddDevice)
{
    auto a = Args(env, info, 2);
    return Bool(env, libjami::confirmAddDevice(ToStr(env, a[0]), static_cast<uint32_t>(ToInt(env, a[1]))));
}
FN(CancelAddDevice)
{
    auto a = Args(env, info, 2);
    return Bool(env, libjami::cancelAddDevice(ToStr(env, a[0]), static_cast<uint32_t>(ToInt(env, a[1]))));
}
FN(ProvideAccountAuthentication)
{
    auto a = Args(env, info, 3);
    return Bool(env, libjami::provideAccountAuthentication(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2])));
}

// ---------------------------------------------------------------------------- conferences

FN(GetActiveCalls) { auto a = Args(env, info, 2); return MapVec(env, libjami::getActiveCalls(ToStr(env, a[0]), ToStr(env, a[1]))); }
FN(JoinParticipant)
{
    auto a = Args(env, info, 4);
    return Bool(env, libjami::joinParticipant(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3])));
}
FN(AddParticipant)
{
    auto a = Args(env, info, 4);
    return Bool(env, libjami::addParticipant(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3])));
}
FN(JoinConference)
{
    auto a = Args(env, info, 4);
    return Bool(env, libjami::joinConference(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3])));
}
FN(HangUpConference) { auto a = Args(env, info, 2); return Bool(env, libjami::hangUpConference(ToStr(env, a[0]), ToStr(env, a[1]))); }
FN(HoldConference) { auto a = Args(env, info, 2); return Bool(env, libjami::holdConference(ToStr(env, a[0]), ToStr(env, a[1]))); }
FN(ResumeConference) { auto a = Args(env, info, 2); return Bool(env, libjami::resumeConference(ToStr(env, a[0]), ToStr(env, a[1]))); }
FN(GetConferenceList) { auto a = Args(env, info, 1); return Vec(env, libjami::getConferenceList(ToStr(env, a[0]))); }
FN(GetParticipantList) { auto a = Args(env, info, 2); return Vec(env, libjami::getParticipantList(ToStr(env, a[0]), ToStr(env, a[1]))); }
FN(GetConferenceId) { auto a = Args(env, info, 2); return Str(env, libjami::getConferenceId(ToStr(env, a[0]), ToStr(env, a[1]))); }
FN(GetConferenceDetails) { auto a = Args(env, info, 2); return Map(env, libjami::getConferenceDetails(ToStr(env, a[0]), ToStr(env, a[1]))); }
FN(GetConferenceInfos) { auto a = Args(env, info, 2); return MapVec(env, libjami::getConferenceInfos(ToStr(env, a[0]), ToStr(env, a[1]))); }
FN(SetConferenceLayout)
{
    auto a = Args(env, info, 3);
    libjami::setConferenceLayout(ToStr(env, a[0]), ToStr(env, a[1]), static_cast<uint32_t>(ToInt(env, a[2])));
    return Undef(env);
}
FN(SetModerator)
{
    auto a = Args(env, info, 4);
    libjami::setModerator(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToBool(env, a[3]));
    return Undef(env);
}
FN(MuteStream)
{
    auto a = Args(env, info, 6);
    libjami::muteStream(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3]), ToStr(env, a[4]), ToBool(env, a[5]));
    return Undef(env);
}
FN(SetActiveStream)
{
    auto a = Args(env, info, 6);
    libjami::setActiveStream(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3]), ToStr(env, a[4]), ToBool(env, a[5]));
    return Undef(env);
}
FN(SetActiveParticipant)
{
    auto a = Args(env, info, 3);
    libjami::setActiveParticipant(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]));
    return Undef(env);
}
FN(HangupParticipant)
{
    auto a = Args(env, info, 4);
    libjami::hangupParticipant(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3]));
    return Undef(env);
}
FN(RaiseHand)
{
    auto a = Args(env, info, 5);
    libjami::raiseHand(ToStr(env, a[0]), ToStr(env, a[1]), ToStr(env, a[2]), ToStr(env, a[3]), ToBool(env, a[4]));
    return Undef(env);
}
FN(SendCallTextMessage)
{
    auto a = Args(env, info, 5);
    libjami::sendTextMessage(ToStr(env, a[0]), ToStr(env, a[1]), ToMap(env, a[2]), ToStr(env, a[3]), ToBool(env, a[4]));
    return Undef(env);
}
FN(ToggleRecording) { auto a = Args(env, info, 2); return Bool(env, libjami::toggleRecording(ToStr(env, a[0]), ToStr(env, a[1]))); }

// ---------------------------------------------------------------------------- video

/**
 * Decoded frames of one sink, drawn onto an XComponent surface. The daemon pushes frames on its
 * own thread; each is converted to RGBA straight into a window buffer (iOS: Renderer).
 */
class SurfaceRenderer
{
public:
    SurfaceRenderer(OHNativeWindow* window, uint64_t surfaceId) : window_(window), surfaceId_(surfaceId)
    {
        // Before any geometry is set the window reports the XComponent's own size.
        int32_t h = 0, w = 0;
        OH_NativeWindow_NativeWindowHandleOpt(window_, GET_BUFFER_GEOMETRY, &h, &w);
        surfaceW_ = w;
        surfaceH_ = h;
    }
    ~SurfaceRenderer()
    {
        sws_freeContext(sws_);
        OH_NativeWindow_DestroyNativeWindow(window_);
    }

    uint64_t surfaceId() const { return surfaceId_; }

    /** Swift `VideoScalingPolicy`: 0 aspectFill (crop), 1 aspectFit (whole frame), 2 automatic. */
    void setScaling(int policy) { scaling_ = policy; }

    void draw(const AVFrame* frame)
    {
        std::lock_guard lock(mutex_);
        // The sender tags its frames with a display matrix (phones send sensor-oriented
        // frames); the compositor applies the rotation, so no pixel is moved here.
        int rotation = 0;
        if (const AVFrameSideData* side = av_frame_get_side_data(frame, AV_FRAME_DATA_DISPLAYMATRIX)) {
            double angle = av_display_rotation_get(reinterpret_cast<const int32_t*>(side->data));
            if (!std::isnan(angle)) {
                // The matrix angle is counter-clockwise; the window transform turns clockwise.
                rotation = ((-static_cast<int>(std::lround(angle)) % 360) + 360) % 360;
            }
        }
        if (rotation != rotation_) {
            rotation_ = rotation;
            OH_NativeWindow_NativeWindowHandleOpt(window_, SET_TRANSFORM,
                                                  rotation == 90    ? NATIVEBUFFER_ROTATE_90
                                                  : rotation == 180 ? NATIVEBUFFER_ROTATE_180
                                                  : rotation == 270 ? NATIVEBUFFER_ROTATE_270
                                                                    : NATIVEBUFFER_ROTATE_NONE);
        }
        // A geometry this renderer did not set is the XComponent's new size: it was resized (a PiP
        // window zoomed) while this renderer, kept across re-attaches, still has the old one.
        int32_t h = 0, w = 0;
        OH_NativeWindow_NativeWindowHandleOpt(window_, GET_BUFFER_GEOMETRY, &h, &w);
        if (width_ > 0 && (w != width_ || h != height_)) {
            surfaceW_ = w;
            surfaceH_ = h;
            width_ = 0;
        }
        // Scale into the surface's own size (the tile), cropping to its aspect - Swift tiles
        // are aspectFill. A rotated buffer is laid out in the surface's turned dimensions.
        int targetW = surfaceW_ > 0 ? surfaceW_ : frame->width;
        int targetH = surfaceH_ > 0 ? surfaceH_ : frame->height;
        if (rotation == 90 || rotation == 270) {
            std::swap(targetW, targetH);
        }
        if (targetW != width_ || targetH != height_) {
            width_ = targetW;
            height_ = targetH;
            OH_NativeWindow_NativeWindowHandleOpt(window_, SET_BUFFER_GEOMETRY, width_, height_);
            OH_NativeWindow_NativeWindowHandleOpt(window_, SET_FORMAT, NATIVEBUFFER_PIXEL_FMT_RGBA_8888);
            OH_NativeWindow_NativeWindowHandleOpt(window_, SET_USAGE,
                                                  NATIVEBUFFER_USAGE_CPU_READ | NATIVEBUFFER_USAGE_CPU_WRITE |
                                                      NATIVEBUFFER_USAGE_MEM_DMA);
        }
        std::unique_ptr<AVFrame, void (*)(AVFrame*)> src(av_frame_clone(frame), [](AVFrame* f) { av_frame_free(&f); });
        if (!src) {
            return;
        }
        const int64_t lhs = static_cast<int64_t>(src->width) * height_;
        const int64_t rhs = static_cast<int64_t>(src->height) * width_;
        // Whole frame: scale the full frame into a centred, aspect-kept rect; black bars around.
        // Swift `VideoScaling.shouldShowWholeFrame`: automatic shows the whole frame when frame and
        // tile aspects differ by more than 1.3. Both sides are in buffer space, so rotation cancels.
        const int policy = scaling_;
        const bool mismatched = lhs > 0 && rhs > 0 &&
            std::max(static_cast<double>(lhs) / rhs, static_cast<double>(rhs) / lhs) > 1.3;
        const bool wholeFrame = policy == 1 || (policy == 2 && mismatched);
        int dstW = width_;
        int dstH = height_;
        if (wholeFrame && lhs > rhs) {
            dstH = std::max(2, static_cast<int>(static_cast<int64_t>(src->height) * width_ / src->width) & ~1);
        } else if (wholeFrame && lhs < rhs) {
            dstW = std::max(2, static_cast<int>(static_cast<int64_t>(src->width) * height_ / src->height) & ~1);
        } else if (lhs > rhs) { // source wider than the tile: crop the sides
            const int keep = static_cast<int>(rhs / height_) & ~1;
            src->crop_left = static_cast<size_t>((src->width - keep) / 2) & ~static_cast<size_t>(1);
            src->crop_right = static_cast<size_t>(src->width - keep) - src->crop_left;
        } else if (lhs < rhs) { // taller: crop top and bottom
            const int keep = static_cast<int>(lhs / width_) & ~1;
            src->crop_top = static_cast<size_t>((src->height - keep) / 2) & ~static_cast<size_t>(1);
            src->crop_bottom = static_cast<size_t>(src->height - keep) - src->crop_top;
        }
        av_frame_apply_cropping(src.get(), AV_FRAME_CROP_UNALIGNED);
        sws_ = sws_getCachedContext(sws_, src->width, src->height, static_cast<AVPixelFormat>(src->format), dstW,
                                    dstH, AV_PIX_FMT_RGBA, SWS_BILINEAR, nullptr, nullptr, nullptr);
        if (sws_ == nullptr) {
            return;
        }
        OHNativeWindowBuffer* buffer = nullptr;
        int fenceFd = -1;
        if (OH_NativeWindow_NativeWindowRequestBuffer(window_, &buffer, &fenceFd) != 0) {
            return;
        }
        if (fenceFd >= 0) {
            close(fenceFd);
        }
        BufferHandle* handle = OH_NativeWindow_GetBufferHandleFromNative(buffer);
        // A resize on the UI thread can land between the check above and this request: a buffer
        // smaller than the layout is never drawn into (T-1385: sws_scale overran one, SIGSEGV).
        if (handle->stride < width_ * 4 || handle->height < height_) {
            OH_NativeWindow_NativeWindowAbortBuffer(window_, buffer);
            return;
        }
        void* addr = handle->virAddr;
        bool mapped = false;
        if (addr == nullptr) {
            addr = mmap(nullptr, handle->size, PROT_READ | PROT_WRITE, MAP_SHARED, handle->fd, 0);
            mapped = addr != MAP_FAILED;
            if (!mapped) {
                OH_NativeWindow_NativeWindowAbortBuffer(window_, buffer);
                return;
            }
        }
        uint8_t* base = static_cast<uint8_t*>(addr);
        if (dstW != width_ || dstH != height_) {
            // Opaque black bars: every pixel 0,0,0,255 before the frame is drawn over the middle.
            for (int y = 0; y < height_; ++y) {
                uint32_t* row = reinterpret_cast<uint32_t*>(base + static_cast<size_t>(y) * handle->stride);
                std::fill(row, row + width_, 0xFF000000u);
            }
            base += static_cast<size_t>((height_ - dstH) / 2) * handle->stride + static_cast<size_t>((width_ - dstW) / 2) * 4;
        }
        uint8_t* dst[4] = {base, nullptr, nullptr, nullptr};
        int dstStride[4] = {handle->stride, 0, 0, 0};
        sws_scale(sws_, src->data, src->linesize, 0, src->height, dst, dstStride);
        if (mapped) {
            munmap(addr, handle->size);
        }
        Region::Rect rect {0, 0, static_cast<uint32_t>(width_), static_cast<uint32_t>(height_)};
        Region region {&rect, 1};
        OH_NativeWindow_NativeWindowFlushBuffer(window_, buffer, -1, region);
    }

private:
    std::mutex mutex_;
    OHNativeWindow* window_;
    const uint64_t surfaceId_;
    SwsContext* sws_ {nullptr};
    int width_ {0};
    int height_ {0};
    int rotation_ {0};
    int surfaceW_ {0};
    int surfaceH_ {0};
    std::atomic<int> scaling_ {0};
};

std::mutex g_renderersMutex;
std::map<std::string, std::shared_ptr<SurfaceRenderer>> g_renderers;
/** Each sink's scaling policy; kept so a re-attached surface keeps the choice. Default: 0 (fill). */
std::map<std::string, int> g_sinkScaling;

/** attachSink(sinkId: string, surfaceId: string): boolean */
FN(AttachSink)
{
    auto a = Args(env, info, 2);
    std::string sinkId = ToStr(env, a[0]);
    const uint64_t surfaceId = std::stoull(ToStr(env, a[1]));
    std::shared_ptr<SurfaceRenderer> renderer;
    {
        std::lock_guard lock(g_renderersMutex);
        // DecodingStarted after a renegotiation (a camera toggle) attaches the same surface again.
        // A new renderer would read the geometry the old one set, turned for a rotated stream, as
        // the tile's size (T-1377: the peer became a strip on every other toggle): keep the old one.
        auto it = g_renderers.find(sinkId);
        if (it != g_renderers.end() && it->second->surfaceId() == surfaceId) {
            renderer = it->second;
        } else {
            OHNativeWindow* window = nullptr;
            if (OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &window) != 0) {
                return Bool(env, false);
            }
            renderer = std::make_shared<SurfaceRenderer>(window, surfaceId);
            auto scaling = g_sinkScaling.find(sinkId);
            renderer->setScaling(scaling == g_sinkScaling.end() ? 0 : scaling->second);
            g_renderers[sinkId] = renderer;
        }
    }
    libjami::SinkTarget target;
    // The frame size as shown (a quarter-turn display matrix swaps it), sent to ArkTS only when it
    // changes: the picture-in-picture window takes the video's aspect (T-1592). Runs on the
    // decoder thread; Emit is thread-safe.
    auto shown = std::make_shared<std::atomic<int64_t>>(0);
    target.push = [renderer, sinkId, shown](libjami::FrameBuffer frame) {
        renderer->draw(frame.get());
        int w = frame->width;
        int h = frame->height;
        if (const AVFrameSideData* side = av_frame_get_side_data(frame.get(), AV_FRAME_DATA_DISPLAYMATRIX)) {
            double angle = av_display_rotation_get(reinterpret_cast<const int32_t*>(side->data));
            if (!std::isnan(angle) && std::lround(std::fabs(angle)) % 180 == 90) {
                std::swap(w, h);
            }
        }
        const int64_t packed = (static_cast<int64_t>(w) << 32) | static_cast<uint32_t>(h);
        if (shown->exchange(packed) != packed) {
            Emit("SinkFrameSize", Obj({{"sinkId", S(sinkId)}, {"width", N(w)}, {"height", N(h)}}));
        }
    };
    return Bool(env, libjami::registerSinkTarget(sinkId, std::move(target)));
}

/** detachSink(sinkId: string) */
FN(DetachSink)
{
    auto a = Args(env, info, 1);
    std::string sinkId = ToStr(env, a[0]);
    // The sink takes its own lock around every push: once this returns, no frame is in flight.
    libjami::registerSinkTarget(sinkId, libjami::SinkTarget {});
    std::lock_guard lock(g_renderersMutex);
    g_renderers.erase(sinkId);
    return Undef(env);
}

/** setSinkScaling(sinkId: string, policy: number) - 0 crop (fill), 1 whole frame (fit), 2 automatic. */
FN(SetSinkScaling)
{
    auto a = Args(env, info, 2);
    std::string sinkId = ToStr(env, a[0]);
    int policy = static_cast<int>(ToInt(env, a[1]));
    std::lock_guard lock(g_renderersMutex);
    g_sinkScaling[sinkId] = policy;
    auto it = g_renderers.find(sinkId);
    if (it != g_renderers.end()) {
        it->second->setScaling(policy);
    }
    return Undef(env);
}

/** The camera preview stream the daemon encodes: an image receiver whose frames go to one input. */
struct Capture
{
    OH_ImageReceiverNative* receiver {nullptr};
    std::string inputId;
    int rotation {0};
    /** T-1616 timeline: the first frame handed to libjami since StartCapture is logged once. */
    bool firstFrameLogged {false};
};
std::mutex g_captureMutex;
Capture g_capture;

/** NV21 from the camera, copied into the daemon's next frame for the capture input. */
void OnCameraImage(OH_ImageReceiverNative* receiver)
{
    OH_ImageNative* image = nullptr;
    if (OH_ImageReceiverNative_ReadLatestImage(receiver, &image) != IMAGE_SUCCESS || image == nullptr) {
        return;
    }
    std::lock_guard lock(g_captureMutex);
    Image_Size size {};
    // The caller owns the component array: query the count, then fill it.
    size_t typeCount = 0;
    OH_ImageNative_GetComponentTypes(image, nullptr, &typeCount);
    std::vector<uint32_t> typeList(typeCount);
    uint32_t* types = typeList.data();
    OH_NativeBuffer* nb = nullptr;
    int32_t stride = 0;
    void* addr = nullptr;
    if (g_capture.receiver == receiver && typeCount > 0 && OH_ImageNative_GetImageSize(image, &size) == IMAGE_SUCCESS &&
        OH_ImageNative_GetComponentTypes(image, &types, &typeCount) == IMAGE_SUCCESS &&
        OH_ImageNative_GetByteBuffer(image, types[0], &nb) == IMAGE_SUCCESS &&
        OH_ImageNative_GetRowStride(image, types[0], &stride) == IMAGE_SUCCESS &&
        OH_NativeBuffer_Map(nb, &addr) == 0) {
        if (auto* out = libjami::getNewFrame(g_capture.inputId)) {
            AVFrame* f = out->pointer();
            f->format = AV_PIX_FMT_NV21;
            f->width = static_cast<int>(size.width);
            f->height = static_cast<int>(size.height);
            if (av_frame_get_buffer(f, 0) == 0) {
                const auto* src = static_cast<const uint8_t*>(addr);
                for (int y = 0; y < f->height; y++) {
                    memcpy(f->data[0] + y * f->linesize[0], src + y * stride, f->width);
                }
                const uint8_t* uv = src + static_cast<size_t>(stride) * f->height;
                for (int y = 0; y < f->height / 2; y++) {
                    memcpy(f->data[1] + y * f->linesize[1], uv + y * stride, f->width);
                }
                if (g_capture.rotation != 0) {
                    if (AVFrameSideData* side = av_frame_new_side_data(f, AV_FRAME_DATA_DISPLAYMATRIX, sizeof(int32_t) * 9)) {
                        av_display_rotation_set(reinterpret_cast<int32_t*>(side->data), g_capture.rotation);
                    }
                }
                libjami::publishFrame(g_capture.inputId);
                if (!g_capture.firstFrameLogged) {
                    g_capture.firstFrameLogged = true;
                    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, "JamiF4",
                                 "first camera frame published to libjami %{public}s (%{public}ux%{public}u)",
                                 g_capture.inputId.c_str(), size.width, size.height);
                }
            }
        }
        OH_NativeBuffer_Unmap(nb);
    }
    OH_ImageNative_Release(image);
}

void StopCaptureLocked()
{
    if (g_capture.receiver != nullptr) {
        OH_ImageReceiverNative_Off(g_capture.receiver);
        OH_ImageReceiverNative_Release(g_capture.receiver);
        g_capture.receiver = nullptr;
    }
}

/**
 * startCapture(inputId: string, width: number, height: number, rotation: number): string
 * Returns the surface id the camera's second preview output writes to ('' on failure).
 */
FN(StartCapture)
{
    auto a = Args(env, info, 4);
    std::lock_guard lock(g_captureMutex);
    StopCaptureLocked();
    g_capture.inputId = ToStr(env, a[0]);
    g_capture.rotation = static_cast<int>(ToInt(env, a[3]));
    g_capture.firstFrameLogged = false;
    OH_ImageReceiverOptions* options = nullptr;
    if (OH_ImageReceiverOptions_Create(&options) != IMAGE_SUCCESS) {
        return Str(env, "");
    }
    OH_ImageReceiverOptions_SetSize(options, {static_cast<uint32_t>(ToInt(env, a[1])), static_cast<uint32_t>(ToInt(env, a[2]))});
    OH_ImageReceiverOptions_SetCapacity(options, 4);
    OH_ImageReceiverNative* receiver = nullptr;
    auto created = OH_ImageReceiverNative_Create(options, &receiver);
    OH_ImageReceiverOptions_Release(options);
    uint64_t surfaceId = 0;
    if (created != IMAGE_SUCCESS || OH_ImageReceiverNative_GetReceivingSurfaceId(receiver, &surfaceId) != IMAGE_SUCCESS) {
        if (receiver != nullptr) {
            OH_ImageReceiverNative_Release(receiver);
        }
        return Str(env, "");
    }
    g_capture.receiver = receiver;
    OH_ImageReceiverNative_On(receiver, OnCameraImage);
    return Str(env, std::to_string(surfaceId));
}

/** stopCapture() */
FN(StopCapture)
{
    std::lock_guard lock(g_captureMutex);
    StopCaptureLocked();
    return Undef(env);
}

/**
 * openVideoInput(path: string): string - libjami's client-fed input for `path` (camera://...),
 * kept open until closeVideoInput; libjami asks for its frames with StartCapture (iOS: VideoAdapter).
 */
FN(OpenVideoInput) { auto a = Args(env, info, 1); return Str(env, libjami::openVideoInput(ToStr(env, a[0]))); }
FN(CloseVideoInput) { auto a = Args(env, info, 1); return Bool(env, libjami::closeVideoInput(ToStr(env, a[0]))); }
/**
 * startLocalMediaRecorder(videoInputId: string, filepath: string): string - the path written
 * (libjami adds .webm, or .ogg with no video input), '' when refused. iOS: startLocalRecording.
 */
FN(StartLocalMediaRecorder)
{
    auto a = Args(env, info, 2);
    return Str(env, libjami::startLocalMediaRecorder(ToStr(env, a[0]), ToStr(env, a[1])));
}
FN(StopLocalRecorder) { auto a = Args(env, info, 1); libjami::stopLocalRecorder(ToStr(env, a[0])); return Undef(env); }

/** addVideoDevice(name: string, devInfo: Record<string,string>[]) */
FN(AddVideoDevice)
{
    auto a = Args(env, info, 2);
    libjami::addVideoDevice(ToStr(env, a[0]), ToMapVec(env, a[1]));
    return Undef(env);
}
FN(SetDefaultDevice) { auto a = Args(env, info, 1); libjami::setDefaultDevice(ToStr(env, a[0])); return Undef(env); }
FN(GetDefaultDevice) { return Str(env, libjami::getDefaultDevice()); }
/** Swift `video.setDecodingAccelerated` / `setEncodingAccelerated` (T-1593), and their read-back. */
FN(SetDecodingAccelerated) { auto a = Args(env, info, 1); libjami::setDecodingAccelerated(ToBool(env, a[0])); return Undef(env); }
FN(SetEncodingAccelerated) { auto a = Args(env, info, 1); libjami::setEncodingAccelerated(ToBool(env, a[0])); return Undef(env); }
FN(GetDecodingAccelerated) { return Bool(env, libjami::getDecodingAccelerated()); }
FN(GetEncodingAccelerated) { return Bool(env, libjami::getEncodingAccelerated()); }

} // namespace

EXTERN_C_START
static napi_value Export(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
#define P(js, c) {js, nullptr, c, nullptr, nullptr, nullptr, napi_default, nullptr}
        P("init", Init),
        P("version", Version),
        P("connectivityChanged", ConnectivityChanged),
        P("getAccountList", GetAccountList),
        P("getAccountDetails", GetAccountDetails),
        P("getVolatileAccountDetails", GetVolatileAccountDetails),
        P("getAccountTemplate", GetAccountTemplate),
        P("addAccount", AddAccount),
        P("setAccountDetails", SetAccountDetails),
        P("setAccountActive", SetAccountActive),
        P("removeAccount", RemoveAccount),
        P("lookupName", LookupName),
        P("lookupAddress", LookupAddress),
        P("registerName", RegisterName),
        P("sendTrustRequest", SendTrustRequest),
        P("acceptTrustRequest", AcceptTrustRequest),
        P("discardTrustRequest", DiscardTrustRequest),
        P("getTrustRequests", GetTrustRequests),
        P("addContact", AddContact),
        P("removeContact", RemoveContact),
        P("getContacts", GetContacts),
        P("getContactDetails", GetContactDetails),
        P("getConversations", GetConversations),
        P("getConversationRequests", GetConversationRequests),
        P("startConversation", StartConversation),
        P("acceptConversationRequest", AcceptConversationRequest),
        P("declineConversationRequest", DeclineConversationRequest),
        P("removeConversation", RemoveConversation),
        P("conversationInfos", ConversationInfos),
        P("getConversationMembers", GetConversationMembers),
        P("createCollaborativeDocument", CreateCollaborativeDocument),
        P("openCollaborativeDocument", OpenCollaborativeDocument),
        P("closeCollaborativeDocument", CloseCollaborativeDocument),
        P("removeCollaborativeDocument", RemoveCollaborativeDocument),
        P("removeCollaborativeDocumentLocally", RemoveCollaborativeDocumentLocally),
        P("applyCollaborativeUpdate", ApplyCollaborativeUpdate),
        P("collaborativeDocumentState", CollaborativeDocumentState),
        P("collaborativeDocumentStateAt", CollaborativeDocumentStateAt),
        P("setCollaborativeAwareness", SetCollaborativeAwareness),
        P("setCollaborativeDocumentName", SetCollaborativeDocumentName),
        P("collaborativeDocumentName", CollaborativeDocumentName),
        P("getCollaborativeDocuments", GetCollaborativeDocuments),
        P("getCollaborativeDocumentHistory", GetCollaborativeDocumentHistory),
        P("addCollaborativeAttachment", AddCollaborativeAttachment),
        P("collaborativeAttachment", CollaborativeAttachment),
        P("addConversationMember", AddConversationMember),
        P("sendMessage", SendMessage),
        P("loadConversation", LoadConversation),
        P("clearCache", ClearCache),
        P("setMessageDisplayed", SetMessageDisplayed),
        P("setIsComposing", SetIsComposing),
        P("countInteractions", CountInteractions),
        P("placeCallWithMedia", PlaceCallWithMedia),
        P("acceptWithMedia", AcceptWithMedia),
        P("refuse", Refuse),
        P("hangUp", HangUp),
        P("hold", Hold),
        P("resume", Resume),
        P("muteLocalMedia", MuteLocalMedia),
        P("getCallDetails", GetCallDetails),
        P("getCallList", GetCallList),
        P("answerMediaChangeRequest", AnswerMediaChangeRequest),
        P("playDTMF", PlayDTMF),
        P("requestMediaChange", RequestMediaChange),
        P("currentMediaList", CurrentMediaList),
        P("setAudioOutputDevice", SetAudioOutputDevice),
        P("getConversationPreferences", GetConversationPreferences),
        P("updateConversationInfos", UpdateConversationInfos),
        P("setConversationPreferences", SetConversationPreferences),
        P("removeConversationMember", RemoveConversationMember),
        P("loadConversationUntil", LoadConversationUntil),
        P("sendAccountTextMessage", SendAccountTextMessage),
        P("sendFile", SendFile),
        P("downloadFile", DownloadFile),
        P("cancelDataTransfer", CancelDataTransfer),
        P("fileTransferInfo", FileTransferInfo),
        P("subscribeBuddy", SubscribeBuddy),
        P("publishPresence", PublishPresence),
        P("updateProfile", UpdateProfile),
        P("searchUser", SearchUser),
        P("queryPeerServices", QueryPeerServices),
        P("openServiceTunnel", OpenServiceTunnel),
        P("closeServiceTunnel", CloseServiceTunnel),
        P("monitor", Monitor),
        P("getCredentials", GetCredentials),
        P("setCredentials", SetCredentials),
        P("sendRegister", SendRegister),
        P("changeAccountPassword", ChangeAccountPassword),
        P("isPasswordValid", IsPasswordValid),
        P("exportToFile", ExportToFile),
        P("revokeDevice", RevokeDevice),
        P("getKnownRingDevices", GetKnownRingDevices),
        P("addDevice", AddDevice),
        P("confirmAddDevice", ConfirmAddDevice),
        P("cancelAddDevice", CancelAddDevice),
        P("provideAccountAuthentication", ProvideAccountAuthentication),
        P("getActiveCalls", GetActiveCalls),
        P("joinParticipant", JoinParticipant),
        P("addParticipant", AddParticipant),
        P("joinConference", JoinConference),
        P("hangUpConference", HangUpConference),
        P("holdConference", HoldConference),
        P("resumeConference", ResumeConference),
        P("getConferenceList", GetConferenceList),
        P("getParticipantList", GetParticipantList),
        P("getConferenceId", GetConferenceId),
        P("getConferenceDetails", GetConferenceDetails),
        P("getConferenceInfos", GetConferenceInfos),
        P("setConferenceLayout", SetConferenceLayout),
        P("setModerator", SetModerator),
        P("muteStream", MuteStream),
        P("setActiveStream", SetActiveStream),
        P("setActiveParticipant", SetActiveParticipant),
        P("hangupParticipant", HangupParticipant),
        P("raiseHand", RaiseHand),
        P("sendCallTextMessage", SendCallTextMessage),
        P("toggleRecording", ToggleRecording),
        P("attachSink", AttachSink),
        P("detachSink", DetachSink),
        P("setSinkScaling", SetSinkScaling),
        P("startCapture", StartCapture),
        P("stopCapture", StopCapture),
        P("openVideoInput", OpenVideoInput),
        P("closeVideoInput", CloseVideoInput),
        P("startLocalMediaRecorder", StartLocalMediaRecorder),
        P("stopLocalRecorder", StopLocalRecorder),
        P("addVideoDevice", AddVideoDevice),
        P("setDefaultDevice", SetDefaultDevice),
        P("getDefaultDevice", GetDefaultDevice),
        P("setDecodingAccelerated", SetDecodingAccelerated),
        P("setEncodingAccelerated", SetEncodingAccelerated),
        P("getDecodingAccelerated", GetDecodingAccelerated),
        P("getEncodingAccelerated", GetEncodingAccelerated),
#undef P
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Export,
    .nm_modname = "jami",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterJamiModule() { napi_module_register(&g_module); }
