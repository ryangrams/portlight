// SU Remote — Studio Upgrade. MIT licensed; see app/LICENSE.
#include "nlohmann/json.hpp"
#include <algorithm>
#include <chrono>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#endif
using json=nlohmann::json;
namespace fs=std::filesystem;
using NetworkCall=std::function<json(const std::string&,const std::string&,const json&)>;
static std::string env(const char* name) { const char* p=std::getenv(name);return p?p:""; }
static bool validID(const std::string& id) {return id.size()==16 && std::all_of(id.begin(),id.end(),[](unsigned char c){return std::isxdigit(c);});}
static std::string normalizedID(std::string id) {if(!validID(id)) throw std::runtime_error("Network IDs must contain exactly 16 hexadecimal characters.");std::transform(id.begin(),id.end(),id.begin(),[](unsigned char c){return char(std::tolower(c));});return id;}
static std::string readFile(const fs::path& path,size_t limit=2*1024*1024) {
    std::ifstream in(path,std::ios::binary);if(!in)return "";
    std::string result;char buffer[4096];while(in){in.read(buffer,sizeof(buffer));result.append(buffer,size_t(in.gcount()));if(result.size()>limit)throw std::runtime_error("Local data exceeds the size limit.");}return result;
}
static fs::path stateDirectory() {
#ifdef _WIN32
    auto home=env("LOCALAPPDATA");if(home.empty())throw std::runtime_error("Windows local app-data directory unavailable.");
    return fs::path(home)/"Studio Upgrade"/"SU Remote"/"ZeroTier";
#else
    auto home=env("HOME");if(home.empty())throw std::runtime_error("Home directory unavailable.");
    return fs::path(home)/"Library"/"Application Support"/"SU Remote"/"ZeroTier";
#endif
}
class FileLock {
#ifdef _WIN32
    HANDLE handle=INVALID_HANDLE_VALUE;
#else
    int handle=-1;
#endif
public:
    explicit FileLock(const fs::path& dir){fs::create_directories(dir);
#ifdef _WIN32
        handle=CreateFileW((dir/"policy.lock").wstring().c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
        if(handle==INVALID_HANDLE_VALUE)throw std::runtime_error("Another ZeroTier operation is in progress.");
#else
        chmod(dir.c_str(),0700);handle=open((dir/"policy.lock").c_str(),O_RDWR|O_CREAT,0600);
        if(handle<0||flock(handle,LOCK_EX|LOCK_NB)<0){if(handle>=0)close(handle);handle=-1;throw std::runtime_error("Another ZeroTier operation is in progress.");}
#endif
    }
    ~FileLock(){
#ifdef _WIN32
        if(handle!=INVALID_HANDLE_VALUE)CloseHandle(handle);
#else
        if(handle>=0){flock(handle,LOCK_UN);close(handle);}
#endif
    }
};
static std::string token() {
    std::vector<fs::path> paths;
#ifdef _WIN32
    paths={fs::path(env("LOCALAPPDATA"))/"ZeroTier"/"authtoken.secret",fs::path(env("LOCALAPPDATA"))/"ZeroTier"/"One"/"authtoken.secret",fs::path(env("ProgramData"))/"ZeroTier"/"One"/"authtoken.secret"};
#else
    paths={fs::path(env("HOME"))/"Library"/"Application Support"/"ZeroTier"/"authtoken.secret","/Library/Application Support/ZeroTier/One/authtoken.secret"};
#endif
    for(const auto& path:paths){auto value=readFile(path,8192);while(!value.empty()&&std::isspace((unsigned char)value.back()))value.pop_back();
        if(!value.empty() && value.find_first_of("\r\n") == std::string::npos)return value;}
    throw std::runtime_error("ZeroTier is not installed, or its local access token is unavailable to this user. Open ZeroTier once under this account and retry.");
}
#ifdef _WIN32
using Socket=SOCKET;static constexpr Socket invalidSocket=INVALID_SOCKET;
static void closeSocket(Socket s){closesocket(s);}
#else
using Socket=int;static constexpr Socket invalidSocket=-1;
static void closeSocket(Socket s){close(s);}
#endif
class LocalAPI {
    std::string secret;
public:
    explicit LocalAPI(std::string t):secret(std::move(t)){}
    json operator()(const std::string& method,const std::string& path,const json& body)const {
        if(path!="/status"&&path!="/network"&&!(path.rfind("/network/",0)==0&&validID(path.substr(9))))throw std::runtime_error("Invalid ZeroTier API operation.");
        Socket sock=socket(AF_INET,SOCK_STREAM,0);if(sock==invalidSocket)throw std::runtime_error("Could not open local ZeroTier connection.");
        struct Guard{Socket s;~Guard(){closeSocket(s);}}guard{sock};
#ifdef _WIN32
        DWORD timeout=3000;setsockopt(sock,SOL_SOCKET,SO_RCVTIMEO,(const char*)&timeout,sizeof(timeout));setsockopt(sock,SOL_SOCKET,SO_SNDTIMEO,(const char*)&timeout,sizeof(timeout));
#else
        timeval timeout{3,0};setsockopt(sock,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(sock,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
        int one=1;setsockopt(sock,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
#endif
        sockaddr_in addr{};addr.sin_family=AF_INET;addr.sin_port=htons(9993);inet_pton(AF_INET,"127.0.0.1",&addr.sin_addr);
        if(connect(sock,(sockaddr*)&addr,sizeof(addr))!=0)throw std::runtime_error("The local ZeroTier service is not responding.");
        const std::string payload=body.is_null()?"":body.dump();
        std::string request=method+" "+path+" HTTP/1.1\r\nHost: 127.0.0.1:9993\r\nX-ZT1-Auth: "+secret+"\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: "+std::to_string(payload.size())+"\r\n\r\n"+payload;
        size_t sent=0;while(sent<request.size()){int n=(int)send(sock,request.data()+sent,(int)(request.size()-sent),0);if(n<=0)throw std::runtime_error("Could not send local ZeroTier request.");sent+=size_t(n);}
        std::string response;char buffer[8192];for(;;){int n=(int)recv(sock,buffer,sizeof(buffer),0);if(n<0)throw std::runtime_error("The local ZeroTier service timed out.");if(n==0)break;response.append(buffer,n);if(response.size()>2*1024*1024)throw std::runtime_error("ZeroTier response exceeds the size limit.");}
        auto split=response.find("\r\n\r\n");if(split==std::string::npos)throw std::runtime_error("Invalid response from ZeroTier.");
        int status=0;std::istringstream first(response);std::string version;first>>version>>status;
        if(status<200||status>=300){if(status==401||status==403)throw std::runtime_error("ZeroTier denied local API access. Reopen ZeroTier under this account.");throw std::runtime_error("ZeroTier API operation failed with HTTP "+std::to_string(status)+".");}
        auto headers=response.substr(0,split);std::transform(headers.begin(),headers.end(),headers.begin(),[](unsigned char c){return char(std::tolower(c));});
        std::string content=response.substr(split+4);
        if(headers.find("transfer-encoding: chunked")!=std::string::npos){std::string decoded;size_t pos=0;for(;;){auto e=content.find("\r\n",pos);if(e==std::string::npos)throw std::runtime_error("Invalid chunked ZeroTier response.");size_t size=std::stoul(content.substr(pos,e-pos),nullptr,16);pos=e+2;if(!size)break;if(size>content.size()-pos)throw std::runtime_error("Truncated ZeroTier response.");decoded.append(content,pos,size);pos+=size+2;}content=std::move(decoded);}
        return content.empty()?json::object():json::parse(content);
    }
};
static json properties(const json& network){json out=json::object();for(auto key:{"allowManaged","allowGlobal","allowDefault","allowDNS"})if(network.contains(key)&&network[key].is_boolean())out[key]=network[key];return out;}
static json membership(const json& networks,const std::string& id){for(const auto& n:networks)if(n.value("id",std::string())==id)return {{"joined",true},{"properties",properties(n)}};return {{"joined",false},{"properties",json::object()}};}
static json publicNetworks(const json& networks){json out=json::array();for(const auto& n:networks){json row=json::object();for(auto key:{"id","name","status","assignedAddresses","routes","allowManaged","allowGlobal","allowDefault","allowDNS","portDeviceName","type"})if(n.contains(key))row[key]=n[key];out.push_back(row);}return out;}
class Policy {
    NetworkCall api;json& transactions;std::function<void()> save;
    void applySnapshot(const json& snapshot, const std::function<void()>& progress = []{}) {
        // Remove temporary memberships before restoring older networks with overlapping routes.
        auto current=api("GET","/network",nullptr);
        for(auto i=snapshot.begin();i!=snapshot.end();++i) {
            if(i.value()["joined"]==false && membership(current,i.key())["joined"]==true) {
                api("DELETE","/network/"+i.key(),nullptr); progress();
            }
        }
        for(auto i=snapshot.begin();i!=snapshot.end();++i) {
            if(i.value()["joined"]==true) { api("POST","/network/"+i.key(),i.value()["properties"]); progress(); }
        }
    }
    json snapshot(const json& scope) {auto current=api("GET","/network",nullptr);json out=json::object();for(auto i=scope.begin();i!=scope.end();++i)out[i.key()]=membership(current,i.key());return out;}
public:
    Policy(NetworkCall call,json& tx,std::function<void()> persist):api(std::move(call)),transactions(tx),save(std::move(persist)){}
    json status(){
        json pending=json::array();
        for(const auto& tx:transactions)pending.push_back({{"transactionId",tx.at("id")},{"networkId",tx.at("networkId")},{"sessionId",tx.at("sessionId")},{"phase",tx.at("phase")}});
        try {auto networks=api("GET","/network",nullptr),node=api("GET","/status",nullptr);return {{"ok",true},{"installed",true},{"online",node.value("online",false)},{"networks",publicNetworks(networks)},{"pendingTransactions",pending}};}
        catch(const std::exception& e) {return {{"ok",false},{"online",false},{"message",e.what()},{"networks",json::array()},{"pendingTransactions",pending}};}
    }
    json activate(const json& request){
        const std::string desired=normalizedID(request.at("networkId").get<std::string>()),session=request.at("sessionId").get<std::string>();if(session.empty()||session.size()>128)throw std::runtime_error("A valid viewer session ID is required.");
        std::set<std::string> scope{desired};if(!request.value("managedNetworkIds",json::array()).is_array())throw std::runtime_error("managedNetworkIds must be an array.");for(const auto& id:request.value("managedNetworkIds",json::array()))scope.insert(normalizedID(id.get<std::string>()));if(scope.size()>32)throw std::runtime_error("Too many networks in this preset.");
        for(const auto& tx:transactions){for(const auto& id:scope)if(tx.at("before").contains(id))return {{"ok",false},{"code","busy"},{"message","Another saved network transaction overlaps this preset. Restore it before switching."},{"transactionId",tx.at("id")}};}
        const auto networks=api("GET","/network",nullptr);json before=json::object();for(const auto& id:scope)before[id]=membership(networks,id);
        auto now=std::chrono::high_resolution_clock::now().time_since_epoch().count();const std::string txid=std::to_string(now);
        transactions.push_back({{"id",txid},{"sessionId",session},{"networkId",desired},{"phase","preparing"},{"before",before},{"after",before}});save();
        auto checkpoint=[&]{transactions.back()["after"]=snapshot(before);save();};
        try{
            for(const auto& id:scope)if(id!=desired&&before[id]["joined"]==true){api("DELETE","/network/"+id,nullptr);checkpoint();}
            api("POST","/network/"+desired,before[desired]["properties"]);
            checkpoint();
            bool ready=false;for(int attempt=0;attempt<30;++attempt){auto n=api("GET","/network/"+desired,nullptr);auto st=n.value("status",std::string());if(st=="OK"){ready=true;break;}if(st=="ACCESS_DENIED"||st=="NOT_FOUND")break;std::this_thread::sleep_for(std::chrono::milliseconds(100));}
            if(!ready)throw std::runtime_error("The requested ZeroTier network is not authorized or ready. Previous networks will be restored.");
            auto afterNetworks=api("GET","/network",nullptr);json after=json::object();for(const auto& id:scope)after[id]=membership(afterNetworks,id);
            if(after[desired]["joined"]!=true)throw std::runtime_error("Required network did not remain connected.");
            for(const auto& id:scope)if(id!=desired&&after[id]["joined"]==true)throw std::runtime_error("A conflicting network could not be disconnected.");
            transactions.back()["after"]=after;transactions.back()["phase"]="active";save();
            return {{"ok",true},{"transactionId",txid},{"networks",publicNetworks(afterNetworks)}};
        }catch(const std::exception& e){std::string reason=e.what();try{applySnapshot(before,checkpoint);transactions.erase(transactions.end()-1);save();return {{"ok",false},{"code","activation"},{"message",reason},{"restored",true}};}catch(...){transactions.back()["phase"]="recovery-needed";save();return {{"ok",false},{"code","recovery"},{"message",reason+" Automatic recovery failed; restore this transaction from network status."},{"transactionId",txid}};}}
    }
    json restore(const json& request){const std::string id=request.at("transactionId").get<std::string>();for(size_t index=0;index<transactions.size();++index){auto& tx=transactions[index];if(tx.at("id")!=id)continue;
        if(tx.contains("after")){auto current=api("GET","/network",nullptr);for(auto it=tx["after"].begin();it!=tx["after"].end();++it)if(membership(current,it.key())!=it.value())return {{"ok",false},{"code","changed"},{"message","Network settings changed outside this preset. They have been preserved; review the pending transaction."}};}
        const auto before=tx.at("before");
        tx["phase"]="restoring";save();
        try {applySnapshot(before,[&]{tx["after"]=snapshot(before);save();});}
        catch (...) {tx["phase"]="recovery-needed";save();throw;}
        transactions.erase(transactions.begin()+index);save();return {{"ok",true},{"networks",publicNetworks(api("GET","/network",nullptr))}};
    }return {{"ok",false},{"code","missing"},{"message","Saved network transaction not found."}};}
    json forget(const json& request) {const std::string id=request.at("transactionId").get<std::string>();for(size_t index=0;index<transactions.size();++index)if(transactions[index].at("id")==id){transactions.erase(transactions.begin()+index);save();return {{"ok",true},{"message","Saved restoration state cleared. Network settings were not changed."}};}return {{"ok",false},{"code","missing"},{"message","Saved network transaction not found."}};}
};
static void persist(const fs::path& file,const json& value){auto temp=file;temp+=".tmp";{std::ofstream out(temp,std::ios::binary|std::ios::trunc);out<<value.dump(2);if(!out)throw std::runtime_error("Could not save network restoration state.");}
#ifdef _WIN32
    if(!MoveFileExW(temp.wstring().c_str(),file.wstring().c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))throw std::runtime_error("Could not commit network restoration state.");
#else
    chmod(temp.c_str(),0600);fs::rename(temp,file);
#endif
}
static void require(bool condition,const char* what){if(!condition)throw std::runtime_error(what);}
static int selfTest(){
    const std::string a="aaaaaaaaaaaaaaaa",b="bbbbbbbbbbbbbbbb",unrelated="cccccccccccccccc";
    std::map<std::string,json> members;std::vector<std::string> operations;auto net=[](std::string id){return json{{"id",id},{"name",id},{"status","OK"},{"allowManaged",true},{"allowGlobal",false},{"allowDefault",false},{"allowDNS",false},{"assignedAddresses",json::array({"10.0.0.1/24"})}};};
    members[b]=net(b);members[unrelated]=net(unrelated);json tx=json::array();int saves=0;
    NetworkCall call=[&](const std::string& method,const std::string& path,const json& body)->json{if(path=="/status")return {{"online",true}};if(path=="/network"){json out=json::array();for(auto& pair:members)out.push_back(pair.second);return out;}auto id=path.substr(9);if(method=="DELETE"){operations.push_back("leave "+id);members.erase(id);return json::object();}if(method=="POST"){operations.push_back("join "+id);if(!members.count(id))members[id]=net(id);for(auto i=body.begin();i!=body.end();++i)members[id][i.key()]=i.value();}return members.at(id);};
    Policy p(call,tx,[&]{++saves;});auto result=p.activate({{"networkId",a},{"managedNetworkIds",json::array({a,b})},{"sessionId","test"}});
    require(result["ok"]==true,"activation failed");require(members.count(a)&&!members.count(b)&&members.count(unrelated),"exclusive scope incorrect");
    require(operations.size()>=2&&operations[0]=="leave "+b&&operations[1]=="join "+a,"conflicting network left too late");
    auto blocked=p.activate({{"networkId",b},{"managedNetworkIds",json::array({a,b})},{"sessionId","other"}});require(blocked["code"]=="busy","overlap not rejected");
    auto restored=p.restore({{"transactionId",result["transactionId"]}});require(restored["ok"]==true&&!members.count(a)&&members.count(b)&&members.count(unrelated),"restore incorrect");
    result=p.activate({{"networkId",a},{"managedNetworkIds",json::array({a,b})},{"sessionId","test"}});members[a]["allowDNS"]=true;
    restored=p.restore({{"transactionId",result["transactionId"]}});require(restored["code"]=="changed"&&members[a]["allowDNS"]==true,"manual change overwritten");
    const auto unchanged=members;require(p.forget({{"transactionId",result["transactionId"]}})["ok"]==true&&tx.empty()&&members==unchanged,"forget changed networks");
    members.clear();members[b]=net(b);members[unrelated]=net(unrelated);
    bool failJoin=true;
    Policy failing([&](const std::string& method,const std::string& path,const json& body)->json{if(failJoin&&method=="POST"&&path=="/network/"+a){failJoin=false;throw std::runtime_error("Synthetic join failure");}return call(method,path,body);},tx,[&]{++saves;});
    result=failing.activate({{"networkId",a},{"managedNetworkIds",json::array({a,b})},{"sessionId","failure-test"}});
    require(result["restored"]==true&&tx.empty()&&!members.count(a)&&members.count(b)&&members.count(unrelated),"failed activation did not restore original networks");
    result=p.activate({{"networkId",a},{"managedNetworkIds",json::array({a,b})},{"sessionId","restore-failure-test"}});
    bool failRestore=true;
    Policy interrupted([&](const std::string& method,const std::string& path,const json& body)->json{if(failRestore&&method=="POST"&&path=="/network/"+b){failRestore=false;throw std::runtime_error("Synthetic restoration failure");}return call(method,path,body);},tx,[&]{++saves;});
    try {interrupted.restore({{"transactionId",result["transactionId"]}});require(false,"restore failure not reported");} catch(const std::runtime_error&) {}
    require(!tx.empty()&&tx[0]["phase"]=="recovery-needed","interrupted restore not retained");
    Policy offline([](const std::string&,const std::string&,const json&)->json{throw std::runtime_error("Service offline");},tx,[&]{++saves;});
    require(offline.status()["pendingTransactions"].size()==1,"offline status hides pending recovery");
    restored=interrupted.restore({{"transactionId",result["transactionId"]}});
    require(restored["ok"]==true&&tx.empty()&&!members.count(a)&&members.count(b)&&members.count(unrelated),"interrupted restore cannot be retried");
    require(!validID("../../anything!!"),"ID validation");require(saves>=4,"state not persisted");
    std::cout<<json{{"ok",true},{"tests",json::array({"exclusive group","leave conflicts before join","unrelated networks preserved","overlap refused","state restoration","manual changes preserved","forget preserves networks","activation rollback","retry interrupted restoration","offline recovery visibility","ID validation","durable transaction"})}}.dump()<<"\n";return 0;
}
int main(int argc,char** argv){
#ifdef _WIN32
    WSADATA data;WSAStartup(MAKEWORD(2,2),&data);
#endif
    try{if(argc==2&&std::string(argv[1])=="--self-test")return selfTest();std::string input;char buffer[4096];while(std::cin){std::cin.read(buffer,sizeof(buffer));input.append(buffer,size_t(std::cin.gcount()));if(input.size()>65536)throw std::runtime_error("Request too large.");}auto request=json::parse(input);auto action=request.at("action").get<std::string>();if(action!="status"&&action!="activate"&&action!="restore"&&action!="forget")throw std::runtime_error("Unknown ZeroTier action.");
        FileLock lock(stateDirectory());auto stateFile=stateDirectory()/"transactions.json";auto saved=readFile(stateFile);json transactions=saved.empty()?json::array():json::parse(saved);if(!transactions.is_array())throw std::runtime_error("Invalid network recovery state.");
        NetworkCall call=[&](const std::string& method,const std::string& path,const json& body){return LocalAPI(token())(method,path,body);};Policy policy(call,transactions,[&]{persist(stateFile,transactions);});json result=action=="status"?policy.status():action=="activate"?policy.activate(request):action=="restore"?policy.restore(request):policy.forget(request);std::cout<<result.dump()<<"\n";return result.value("ok",false)?0:1;
    }catch(const std::exception& error){std::cerr<<"SU Remote ZeroTier operation failed.\n";std::cout<<json{{"ok",false},{"message",error.what()}}.dump()<<"\n";return 1;}
}
