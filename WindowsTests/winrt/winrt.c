/* winrt: the two Windows Runtime classes Office's web add-in host needs before it starts a web view (#95):
 * Windows.Data.Json (parse, read, build, write) and Windows.Foundation.Uri (the parts of an address).
 * Calls go through the raw vtables, so the test builds without the Windows Runtime headers.
 *   winrt.exe      prints one PASS/FAIL line per check, exit code 0/1 */
#include <windows.h>
#include <roapi.h>
#include <winstring.h>
#include <stdio.h>

typedef void *obj;   /* an interface pointer */
#define CALL(o, slot, ...) ((HRESULT (WINAPI *)())(*(void ***)(o))[slot])(o, ##__VA_ARGS__)
#define E_ILLEGAL_METHOD_CALL_ ((HRESULT)0x8000000E)
#define WEB_E_JSON_VALUE_NOT_FOUND_ ((HRESULT)0x83750009)

static const GUID IID_ActivationFactory = {0x00000035,0,0,{0xc0,0,0,0,0,0,0,0x46}};
static const GUID IID_JsonValueStatics = {0x5f6b544a,0x2f53,0x48e1,{0x91,0xa3,0xf7,0x8b,0x50,0xa6,0x34,0x5c}};
static const GUID IID_JsonObjectStatics = {0x2289f159,0x54de,0x45d8,{0xab,0xcc,0x22,0x60,0x3f,0xa0,0x66,0xa0}};
static const GUID IID_JsonValue = {0xa3219ecb,0xf0b3,0x4dcd,{0xbe,0xee,0x19,0xd4,0x8c,0xd3,0xed,0x1e}};
static const GUID IID_VectorOfJsonValue = {0xd44662bc,0xdce3,0x59a8,{0x92,0x72,0x4b,0x21,0x0f,0x33,0x90,0x8b}};
static const GUID IID_UriFactory = {0x44a9796f,0x723e,0x4fdf,{0xa2,0x18,0x03,0x3e,0x75,0xb0,0xc0,0x84}};

/* slots after IInspectable's six */
enum { VALUE_STRINGIFY = 7, VALUE_GET_OBJECT = 12 };
enum { OBJECT_SET_NAMED_VALUE = 7, OBJECT_GET_NAMED_OBJECT, OBJECT_GET_NAMED_ARRAY, OBJECT_GET_NAMED_STRING, OBJECT_GET_NAMED_NUMBER };
enum { ARRAY_GET_STRING_AT = 8, ARRAY_GET_NUMBER_AT };
enum { STATICS_PARSE = 6, STATICS_TRY_PARSE, STATICS_CREATE_BOOLEAN, STATICS_CREATE_NUMBER, STATICS_CREATE_STRING };
enum { VECTOR_APPEND = 13 };
enum { URI_EXTENSION = 9, URI_FRAGMENT, URI_HOST, URI_PASSWORD, URI_PATH, URI_QUERY, URI_SCHEME_NAME = 17, URI_USER_NAME, URI_PORT };

static int failed;
static HSTRING str(const WCHAR *s) { HSTRING h = NULL; WindowsCreateString(s, wcslen(s), &h); return h; }
static const WCHAR *text(HSTRING h) { return WindowsGetStringRawBuffer(h, NULL); }
static void check(int ok, const char *what) { printf("%s: %s\n", ok ? "PASS" : "FAIL", what); if (!ok) failed = 1; fflush(stdout); }
static void detail(const char *label, const WCHAR *got) { printf("  %s: %ls\n", label, got); }

static obj statics(const WCHAR *class_name, const GUID *iid)
{
    obj factory = NULL;
    RoGetActivationFactory(str(class_name), iid, &factory);
    return factory;
}

static obj create(const WCHAR *class_name)
{
    obj factory = statics(class_name, &IID_ActivationFactory), instance = NULL;
    if (factory) CALL(factory, 6, &instance);
    return instance;
}

static int part_is(obj uri, int slot, const WCHAR *want)
{
    HSTRING got = NULL;
    if (CALL(uri, slot, &got) != S_OK) return 0;
    if (wcscmp(text(got), want)) { detail("got", text(got)); return 0; }
    return 1;
}

int main(void)
{
    static const WCHAR input[] = L" {\"a\":[1,\"x\\n\\u00e9\",true,null,-2.5e3],\"b\":{\"c\":0.25,\"d\":\"\"}} ";
    static const WCHAR written[] = L"{\"a\":[1,\"x\\né\",true,null,-2500],\"b\":{\"c\":0.25,\"d\":\"\"}}";
    obj value_statics, object_statics, parsed = NULL, object = NULL, array = NULL, inner = NULL, vector = NULL, v = NULL, uri_factory, uri = NULL;
    HSTRING s = NULL; double number = 0; boolean ok = 0; INT32 port = -1; HRESULT hr;

    RoInitialize(RO_INIT_MULTITHREADED);

    if (!(value_statics = statics(L"Windows.Data.Json.JsonValue", &IID_JsonValueStatics))) { check(0, "JsonValue statics"); return 1; }

    hr = CALL(value_statics, STATICS_PARSE, str(input), &parsed);
    if (hr == S_OK) hr = CALL(parsed, VALUE_STRINGIFY, &s);
    if (hr == S_OK && wcscmp(text(s), written)) detail("got", text(s));
    check(hr == S_OK && !wcscmp(text(s), written), "text is parsed and written back");

    hr = CALL(value_statics, STATICS_PARSE, str(L"{\"a\":}"), &v);
    CALL(value_statics, STATICS_TRY_PARSE, str(L"[1,"), &v, &ok);
    check(FAILED(hr) && !ok, "text that isn't JSON is refused");

    hr = parsed ? CALL(parsed, VALUE_GET_OBJECT, &object) : E_FAIL;
    if (hr == S_OK) hr = CALL(object, OBJECT_GET_NAMED_ARRAY, str(L"a"), &array);
    if (hr == S_OK) hr = CALL(array, ARRAY_GET_NUMBER_AT, 0, &number);
    if (hr == S_OK && number == 1) hr = CALL(array, ARRAY_GET_STRING_AT, 1, &s);
    if (hr == S_OK) hr = CALL(object, OBJECT_GET_NAMED_OBJECT, str(L"b"), &inner);
    if (hr == S_OK) hr = CALL(inner, OBJECT_GET_NAMED_NUMBER, str(L"c"), &number);
    check(hr == S_OK && number == 0.25 && !wcscmp(text(s), L"x\né"), "members and elements are read by name and index");

    check(object && CALL(object, OBJECT_GET_NAMED_STRING, str(L"missing"), &s) == WEB_E_JSON_VALUE_NOT_FOUND_ &&
          CALL(object, OBJECT_GET_NAMED_STRING, str(L"a"), &s) == E_ILLEGAL_METHOD_CALL_,
          "a missing member and a member of another type are told apart");

    object = create(L"Windows.Data.Json.JsonObject"); array = create(L"Windows.Data.Json.JsonArray");
    hr = object && array ? CALL(array, 0, &IID_VectorOfJsonValue, &vector) : E_FAIL;
    if (hr == S_OK)
    {
        obj as_value = NULL;
        CALL(value_statics, STATICS_CREATE_STRING, str(L"one"), &v); CALL(vector, VECTOR_APPEND, v);
        ((HRESULT (WINAPI *)(obj, double, obj *))(*(void ***)value_statics)[STATICS_CREATE_NUMBER])(value_statics, 0.1, &v); CALL(vector, VECTOR_APPEND, v);
        CALL(value_statics, STATICS_CREATE_BOOLEAN, TRUE, &v); CALL(vector, VECTOR_APPEND, v);
        CALL(array, 0, &IID_JsonValue, &as_value);
        CALL(object, OBJECT_SET_NAMED_VALUE, str(L"list"), as_value);
        CALL(value_statics, STATICS_CREATE_STRING, str(L"quote\" and \\"), &v); CALL(object, OBJECT_SET_NAMED_VALUE, str(L"text"), v);
        CALL(object, 0, &IID_JsonValue, &as_value);
        hr = CALL(as_value, VALUE_STRINGIFY, &s);
        if (hr == S_OK) detail("built", text(s));
    }
    check(hr == S_OK && !wcscmp(text(s), L"{\"list\":[\"one\",0.1,true],\"text\":\"quote\\\" and \\\\\"}"), "a new object with a new array is built and written");

    object_statics = statics(L"Windows.Data.Json.JsonObject", &IID_JsonObjectStatics);
    hr = object_statics ? CALL(object_statics, STATICS_PARSE, str(L"{\"n\":7}"), &object) : E_FAIL;
    if (hr == S_OK) hr = CALL(object, OBJECT_GET_NAMED_NUMBER, str(L"n"), &number);
    check(hr == S_OK && number == 7 && FAILED(CALL(object_statics, STATICS_PARSE, str(L"[7]"), &object)), "JsonObject.Parse takes an object and nothing else");

    if (!(uri_factory = statics(L"Windows.Foundation.Uri", &IID_UriFactory))) { check(0, "Uri factory"); return 1; }
    hr = CALL(uri_factory, 6, str(L"https://user@example.com:8443/a/b.html?x=1#frag"), &uri);
    check(hr == S_OK && part_is(uri, URI_SCHEME_NAME, L"https") && part_is(uri, URI_USER_NAME, L"user") && part_is(uri, URI_HOST, L"example.com") &&
          part_is(uri, URI_PATH, L"/a/b.html") && part_is(uri, URI_EXTENSION, L".html") && part_is(uri, URI_QUERY, L"?x=1") &&
          part_is(uri, URI_FRAGMENT, L"#frag") && CALL(uri, URI_PORT, &port) == S_OK && port == 8443, "a Uri answers for each of its parts");

    port = -1;
    hr = CALL(uri_factory, 6, str(L"http://example.com/"), &uri);
    check(hr == S_OK && part_is(uri, URI_QUERY, L"") && part_is(uri, URI_PASSWORD, L"") && CALL(uri, URI_PORT, &port) == S_OK && port == 80,
          "parts an address doesn't have are empty, and the port is its scheme's");
    return failed;
}
