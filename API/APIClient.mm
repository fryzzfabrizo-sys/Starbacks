// Local header-only replacement implementation for builds without libAPIClient.a.
// This keeps the project linkable when the original API client library is unavailable.

#import "APIClient.h"

#include <string.h>

static const char *g_token = "";
static const char *g_udid = "";
static const char *g_language = "";
static const char *g_contact_title = "";
static const char *g_description = "";
static bool g_hide_ui = false;
static bool g_strict_mode = false;
static bool g_silent_mode = false;
static int g_window_mode = 0;

extern "C" {

void apiclient_set_token(const char *token) {
    g_token = token ? token : "";
}

void apiclient_set_udid(const char *udid) {
    g_udid = udid ? udid : "";
}

void apiclient_set_language(const char *language) {
    g_language = language ? language : "";
}

void apiclient_set_contact_button_title(const char *title) {
    g_contact_title = title ? title : "";
}

void apiclient_set_description(const char *description) {
    g_description = description ? description : "";
}

void apiclient_hide_ui(bool isHide) {
    g_hide_ui = isHide;
}

void apiclient_strict_mode(bool isStrictMode) {
    g_strict_mode = isStrictMode;
}

void apiclient_silent_mode(bool isSilentMode) {
    g_silent_mode = isSilentMode;
}

void apiclient_set_window_mode(int mode) {
    g_window_mode = mode;
}

void apiclient_paid(apiclient_callback callback) {
    if (callback) {
        callback();
    }
}

const char *apiclient_get_key(void) {
    return "";
}

const char *apiclient_get_udid(void) {
    return g_udid;
}

const char *apiclient_get_expired_at(void) {
    return "";
}

const char *apiclient_get_expired_at_local(void) {
    return "";
}

const char *apiclient_get_device_model(void) {
    return "";
}

const char *apiclient_get_login_ip(void) {
    return "";
}

const char *apiclient_get_package_name(void) {
    return "";
}

const char *apiclient_get_package_data(const char *key) {
    (void)key;
    return "";
}

void apiclient_on_check_package(apiclient_dict_callback success,
                                apiclient_dict_callback failure) {
    (void)failure;
    if (success) {
        success("{}");
    }
}

void apiclient_on_check_device(apiclient_dict_callback success,
                               apiclient_dict_callback failure) {
    (void)failure;
    if (success) {
        success("{}");
    }
}

void apiclient_on_login(const char *inputKey,
                        apiclient_dict_callback success,
                        apiclient_dict_callback failure) {
    (void)inputKey;
    (void)failure;
    if (success) {
        success("{}");
    }
}

}
