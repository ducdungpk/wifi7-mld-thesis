// SPDX-License-Identifier: GPL-2.0-only
// Demo 5: native MLD with Nakagami fading and RandomWalk2d mobility; ns-3.46.1.
// Permanent ARP entries are installed before data traffic; existing CSV schema.
// Throughput: FlowMonitor.rxBytes at IP layer; measurement duration is 9 s.
// Wait for association up to 10 s; then measure exactly 9 s.
#include "ns3/core-module.h"
#include "ns3/flow-monitor-module.h"
#include "ns3/internet-module.h"
#include "ns3/mobility-module.h"
#include "ns3/network-module.h"
#include "ns3/spectrum-module.h"
#include "ns3/wifi-module.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

using namespace ns3;

namespace
{
constexpr uint32_t PAYLOAD = 1200;
constexpr double ACTIVE_TIME = 9.0;
double APP_START = 1.0;
double SIM_STOP = 10.0;
constexpr double SETUP_DEADLINE = 10.0;
constexpr double RADIUS = 5.0;
constexpr std::array<uint16_t, 2> PORTS = {5000, 6000};

std::string mode = "mlo", caseId = "manual", output = ".";
uint32_t nSta = 10, seed = 1;
double speed = 1.5, nakagamiM = 2.0;
uint64_t rngRun = 1, sendErrors = 0;
double offeredLoad = 5.0;
uint8_t nLinks = 2;
bool mappingReady = false;
std::vector<Ptr<WifiNetDevice>> devices;
std::vector<std::array<Ptr<Socket>, 2>> sources;
Ipv4Address apIp;
std::vector<Ipv4Address> staIps;

struct Kpi
{
    uint64_t tx = 0, rx = 0, rxBytes = 0, jitterSamples = 0;
    long double delayNs = 0, jitterNs = 0;

    void AddFlow(const FlowMonitor::FlowStats& f)
    {
        tx += f.txPackets;
        rx += f.rxPackets;
        rxBytes += f.rxBytes;
        delayNs += f.delaySum.GetNanoSeconds();
        jitterNs += f.jitterSum.GetNanoSeconds();
        if (f.rxPackets > 1) jitterSamples += f.rxPackets - 1;
    }

    void Add(const Kpi& other)
    {
        tx += other.tx;
        rx += other.rx;
        rxBytes += other.rxBytes;
        jitterSamples += other.jitterSamples;
        delayNs += other.delayNs;
        jitterNs += other.jitterNs;
    }
};

std::string Number(long double value)
{
    std::ostringstream stream;
    stream << std::setprecision(12) << value;
    return stream.str();
}

long double Throughput(const Kpi& k)
{
    return 8.0L * k.rxBytes / (ACTIVE_TIME * 1e6L);
}

std::string Delay(const Kpi& k)
{
    return k.rx ? Number(k.delayNs / k.rx / 1e6L) : "NA";
}

std::string Jitter(const Kpi& k)
{
    return k.jitterSamples
        ? Number(k.jitterNs / k.jitterSamples / 1e6L) : "NA";
}

std::string Loss(const Kpi& k)
{
    return k.tx
        ? Number(100.0L * (static_cast<long double>(k.tx) - k.rx) / k.tx)
        : "NA";
}

void WriteKpi(std::ostream& stream, const Kpi& k)
{
    stream << k.tx << ',' << k.rx << ',' << k.rxBytes
           << ',' << Number(Throughput(k)) << ',' << Delay(k)
           << ',' << Jitter(k) << ',' << Loss(k);
}

std::string JoinReasons(const std::set<std::string>& reasons)
{
    if (reasons.empty()) return "OK";
    std::ostringstream stream;
    bool first = true;
    for (const auto& reason : reasons)
    {
        if (!first) stream << '|';
        stream << reason;
        first = false;
    }
    return stream.str();
}

// Use the existing IPv4-interface ARP caches. WifiNetDevice::GetAddress()
// gives the device/MLD address; do not use an individual PHY link address.
Ptr<ArpCache> GetCache(Ptr<WifiNetDevice> device)
{
    auto ipv4 = device->GetNode()->GetObject<Ipv4L3Protocol>();
    NS_ABORT_MSG_IF(!ipv4, "IPV4_STACK_MISSING");
    const int32_t index = ipv4->GetInterfaceForDevice(device);
    NS_ABORT_MSG_IF(index < 0, "IPV4_INTERFACE_MISSING");
    auto cache = ipv4->GetInterface(static_cast<uint32_t>(index))->GetArpCache();
    NS_ABORT_MSG_IF(!cache, "ARP_CACHE_MISSING");
    return cache;
}

void SetPermanent(Ptr<ArpCache> cache, Ipv4Address ip, Address mac)
{
    auto entry = cache->Lookup(ip);
    if (!entry) entry = cache->Add(ip);
    entry->SetMacAddress(mac);
    entry->MarkPermanent();
}

void InstallPermanentArp()
{
    auto apCache = GetCache(devices[0]);
    for (uint32_t i = 0; i < nSta; ++i)
    {
        SetPermanent(GetCache(devices[i + 1]), apIp, devices[0]->GetAddress());
        SetPermanent(apCache, staIps[i], devices[i + 1]->GetAddress());
    }
    std::cout << "ARP_SETUP=OK policy=STATIC peers=" << nSta << '\n';
}


std::vector<std::array<uint64_t, 2>> sentOk, appRx;
uint64_t unknownSource = 0;
std::map<uint32_t, uint32_t> sourceLookup;

bool ArpOk(uint32_t i)
{
    auto sta = GetCache(devices[i + 1])->Lookup(apIp);
    auto ap = GetCache(devices[0])->Lookup(staIps[i]);
    return sta && ap && sta->IsPermanent() && ap->IsPermanent() &&
           sta->GetMacAddress() == devices[0]->GetAddress() &&
           ap->GetMacAddress() == devices[i + 1]->GetAddress();
}

void Receive(Ptr<Socket> socket)
{
    Address from, local;
    socket->GetSockName(local);
    const auto port = InetSocketAddress::ConvertFrom(local).GetPort();
    const uint8_t link = port == PORTS[0] ? 0 : 1;
    while (auto packet = socket->RecvFrom(from))
    {
        if (!InetSocketAddress::IsMatchingType(from)) { ++unknownSource; continue; }
        const auto ip = InetSocketAddress::ConvertFrom(from).GetIpv4();
        auto found = sourceLookup.find(ip.Get());
        if (found == sourceLookup.end()) { ++unknownSource; continue; }
        ++appRx[found->second][link];
    }
}

void Send(uint32_t sta, uint8_t link)
{
    if (Simulator::Now() >= Seconds(SIM_STOP)) return;
    auto packet = Create<Packet>(PAYLOAD);
    if (sources[sta][link]->Send(packet) != static_cast<int>(PAYLOAD))
        ++sendErrors;
    else
        ++sentOk[sta][link];

    const double loadPerLink = offeredLoad / nLinks;
    const double interval = PAYLOAD * 8.0 / (loadPerLink * 1e6);
    Simulator::Schedule(Seconds(interval), &Send, sta, link);
}

void ConfigureMapping()
{
    uint32_t readyCount = 0;
    for (uint32_t i = 0; i < nSta; ++i)
    {
        auto mac = DynamicCast<StaWifiMac>(devices[i + 1]->GetMac());
        if (mac->IsAssociated() && mac->GetSetupLinkIds().size() == nLinks)
            ++readyCount;
    }

    if (readyCount != nSta)
    {
        if (Simulator::Now() < Seconds(SETUP_DEADLINE))
        {
            Simulator::Schedule(MilliSeconds(100), &ConfigureMapping);
            return;
        }
        std::cout << "MLD_SETUP=FAIL ready_sta=" << readyCount << '/' << nSta << '\n';
        for (uint32_t i = 0; i < nSta; ++i)
        {
            auto mac = DynamicCast<StaWifiMac>(devices[i + 1]->GetMac());
            if (!mac->IsAssociated() || mac->GetSetupLinkIds().size() != nLinks)
                std::cout << "UNREADY_STA sta_id=" << i
                          << " associated=" << mac->IsAssociated()
                          << " setup_links=" << mac->GetSetupLinkIds().size() << '\n';
        }
        Simulator::Stop();
        return;
    }

    if (nLinks == 2)
    {
        for (uint32_t i = 0; i < nSta; ++i)
        {
            auto mac = DynamicCast<StaWifiMac>(devices[i + 1]->GetMac());
            for (uint8_t phy = 0; phy < 2; ++phy)
            {
                auto blockedLink = mac->GetLinkForPhy(1 - phy);
                if (!blockedLink)
                {
                    std::cout << "MLD_SETUP=FAIL mapping_sta=" << i
                              << " phy=" << +phy << '\n';
                    Simulator::Stop();
                    return;
                }
                mac->GetMacQueueScheduler()->BlockQueues(
                    WifiQueueBlockedReason::TID_NOT_MAPPED,
                    AC_BE, {WIFI_QOSDATA_QUEUE},
                    devices[0]->GetMac()->GetAddress(), mac->GetAddress(),
                    {static_cast<uint8_t>(phy == 0 ? 0 : 3)}, {*blockedLink});
            }
        }
    }

    InstallPermanentArp();
    mappingReady = true;
    APP_START = std::max(1.0, Simulator::Now().GetSeconds() + 0.1);
    SIM_STOP = APP_START + ACTIVE_TIME;
    Simulator::Stop(Seconds(SIM_STOP) - Simulator::Now());
    const Time startDelay = Seconds(APP_START) - Simulator::Now();
    for (uint32_t i = 0; i < nSta; ++i)
        for (uint8_t link = 0; link < nLinks; ++link)
            Simulator::ScheduleWithContext(
                devices[i + 1]->GetNode()->GetId(), startDelay, &Send, i, link);

    std::cout << "MLD_SETUP=OK links_per_sta=" << +nLinks
              << " ready_sta=" << readyCount
              << " app_start_s=" << APP_START << " sim_stop_s=" << SIM_STOP
              << " measure_s=" << ACTIVE_TIME << '\n';
}
} // namespace

int main(int argc, char* argv[])
{
    CommandLine command(__FILE__);
    command.AddValue("mode", "slo5 or mlo", mode);
    command.AddValue("speed", "STA speed in m/s", speed);
    command.AddValue("nakagamiM", "Common Nakagami m0/m1/m2", nakagamiM);
    command.AddValue("nSta", "Number of physical STAs", nSta);
    command.AddValue("offeredLoad", "Total offered UDP Mbps per STA", offeredLoad);
    command.AddValue("seed", "RNG seed", seed);
    command.AddValue("run", "RNG run", rngRun);
    command.AddValue("caseId", "CSV case identifier", caseId);
    command.AddValue("out", "Existing output directory", output);
    command.Parse(argc, argv);
    std::cout << std::unitbuf;

    if (mode != "mlo" || nSta != 10 ||
        !std::isfinite(speed) || speed < 0 || speed > 20 ||
        !std::isfinite(nakagamiM) || nakagamiM < 0.5 || nakagamiM > 4 ||
        !std::isfinite(offeredLoad) || offeredLoad <= 0 || offeredLoad > 500 ||
        !seed || !rngRun || caseId.empty() ||
        caseId.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
            != std::string::npos)
    {
        std::cerr << "INVALID_ARGUMENTS\n";
        return 2;
    }

    std::ofstream summary(output + "/summary.csv");
    std::ofstream perSta(output + "/per_sta.csv");
    std::ofstream perLink(output + "/per_link.csv");
    if (!summary || !perSta || !perLink)
    {
        std::cerr << "OUTPUT_OPEN_FAILED\n";
        return 2;
    }
    summary << std::setprecision(12);
    perSta << std::setprecision(12);
    perLink << std::setprecision(12);
    nLinks = mode == "mlo" ? 2 : 1;

    RngSeedManager::SetSeed(seed);
    RngSeedManager::SetRun(rngRun);
    Config::SetDefault("ns3::HtConfiguration::LdpcSupported", BooleanValue(false));

    NodeContainer ap, stas;
    ap.Create(1);
    stas.Create(nSta);
    auto positions = CreateObject<ListPositionAllocator>();
    positions->Add(Vector(0, 0, 1.5));
    for (uint32_t i = 0; i < nSta; ++i)
    {
        const double angle = 2.0 * std::acos(-1.0) * i / nSta;
        positions->Add(Vector(RADIUS * std::cos(angle), RADIUS * std::sin(angle), 1.5));
    }
    MobilityHelper mobility;
    mobility.SetPositionAllocator(positions);
    mobility.SetMobilityModel("ns3::ConstantPositionMobilityModel");
    mobility.Install(ap);
    if (speed > 0)
        mobility.SetMobilityModel(
            "ns3::RandomWalk2dMobilityModel",
            "Bounds", RectangleValue(Rectangle(-20, 20, -20, 20)),
            "Speed", StringValue("ns3::ConstantRandomVariable[Constant=" +
                                 Number(speed) + "]"),
            "Distance", DoubleValue(5.0));
    mobility.Install(stas);
    mobility.AssignStreams(stas, 30000);

    WifiHelper wifi;
    wifi.SetStandard(WIFI_STANDARD_80211be);
    wifi.ConfigEhtOptions("EmlsrActivated", BooleanValue(false));
    SpectrumWifiPhyHelper phy(nLinks);
    for (uint8_t link = 0; link < nLinks; ++link)
    {
        wifi.SetRemoteStationManager(
            link, "ns3::ConstantRateWifiManager",
            "DataMode", StringValue("EhtMcs9"),
            "ControlMode", StringValue("EhtMcs0"));
        phy.Set(link, "TxPowerStart", DoubleValue(16.0206));
        phy.Set(link, "TxPowerEnd", DoubleValue(16.0206));
        phy.Set(link, "RxNoiseFigure", DoubleValue(7.0));
        phy.Set(link, "MaxSupportedTxSpatialStreams", UintegerValue(1));
        phy.Set(link, "MaxSupportedRxSpatialStreams", UintegerValue(1));
        auto channel = CreateObject<MultiModelSpectrumChannel>();
        auto loss = CreateObject<LogDistancePropagationLossModel>();
        loss->SetAttribute("Exponent", DoubleValue(3.0));
        loss->SetAttribute("ReferenceDistance", DoubleValue(1.0));
        loss->SetAttribute("ReferenceLoss", DoubleValue(46.6777));
        auto fading = CreateObject<NakagamiPropagationLossModel>();
        fading->SetAttribute("m0", DoubleValue(nakagamiM));
        fading->SetAttribute("m1", DoubleValue(nakagamiM));
        fading->SetAttribute("m2", DoubleValue(nakagamiM));
        loss->SetNext(fading);
        loss->AssignStreams(20000 + 100 * link);
        channel->AddPropagationLossModel(loss);
        channel->SetPropagationDelayModel(CreateObject<ConstantSpeedPropagationDelayModel>());
        phy.AddChannel(channel, link == 0 ? WIFI_SPECTRUM_5_GHZ : WIFI_SPECTRUM_6_GHZ);
        phy.Set(link, "ChannelSettings", StringValue(
            link == 0 ? "{36,20,BAND_5GHZ,0}" : "{1,20,BAND_6GHZ,0}"));
    }

    WifiMacHelper mac;
    Ssid ssid("demo5-robustness");
    mac.SetType("ns3::ApWifiMac", "Ssid", SsidValue(ssid));
    auto apDevices = wifi.Install(phy, mac, ap);
    mac.SetType("ns3::StaWifiMac", "Ssid", SsidValue(ssid),
                "ActiveProbing", BooleanValue(false),
                "AssocType", EnumValue(WifiAssocType::ML_SETUP));
    auto staDevices = wifi.Install(phy, mac, stas);
    devices.push_back(DynamicCast<WifiNetDevice>(apDevices.Get(0)));
    for (uint32_t i = 0; i < nSta; ++i)
        devices.push_back(DynamicCast<WifiNetDevice>(staDevices.Get(i)));

    bool topologyOk = true;
    for (const auto& device : devices)
    {
        topologyOk &= device->GetNPhys() == nLinks;
        device->GetHeConfiguration()->SetAttribute("GuardInterval", TimeValue(NanoSeconds(3200)));
        for (uint8_t link = 0; link < nLinks; ++link)
            device->GetPhy(link)->SetErrorRateModel(CreateObject<TableBasedErrorRateModel>());
    }

    InternetStackHelper internet;
    internet.Install(ap);
    internet.Install(stas);
    Ipv4AddressHelper addresses;
    addresses.SetBase("10.81.0.0", "255.255.255.0");
    auto apInterfaces = addresses.Assign(apDevices);
    auto staInterfaces = addresses.Assign(staDevices);
    const auto apAddress = apInterfaces.GetAddress(0);
    apIp = apAddress;
    staIps.resize(nSta);
    std::map<uint32_t, uint32_t> sourceIndex;
    for (uint32_t i = 0; i < nSta; ++i)
    {
        staIps[i] = staInterfaces.GetAddress(i);
        sourceIndex[staIps[i].Get()] = i;
    }

    std::array<Ptr<Socket>, 2> sinks;
    for (uint8_t link = 0; link < nLinks; ++link)
    {
        sinks[link] = Socket::CreateSocket(ap.Get(0), UdpSocketFactory::GetTypeId());
        NS_ABORT_MSG_IF(sinks[link]->Bind(
            InetSocketAddress(Ipv4Address::GetAny(), PORTS[link])), "UDP sink bind failed");
        sinks[link]->SetRecvCallback(MakeCallback(&Receive));
    }
    sources.resize(nSta);
    for (uint32_t i = 0; i < nSta; ++i)
    {
        for (uint8_t link = 0; link < nLinks; ++link)
        {
            auto socket = Socket::CreateSocket(stas.Get(i), UdpSocketFactory::GetTypeId());
            socket->SetIpTos(link == 0 ? 0 : 0x60);
            socket->SetPriority(link == 0 ? 0 : 3);
            NS_ABORT_MSG_IF(socket->Connect(InetSocketAddress(apAddress, PORTS[link])),
                            "UDP source connect failed");
            sources[i][link] = socket;
        }
    }
    sourceLookup = sourceIndex;
    sentOk.resize(nSta);
    appRx.resize(nSta);
    wifi.AssignStreams(apDevices, 100);
    wifi.AssignStreams(staDevices, 10000);
    FlowMonitorHelper flowHelper;
    auto monitor = flowHelper.InstallAll();
    Simulator::Schedule(Seconds(0.9), &ConfigureMapping);
    std::cout << "CONFIG case_id=" << caseId << " mode=" << mode << " n_sta=" << nSta
              << " speed_mps=" << speed << " nakagami_m=" << nakagamiM
              << " offered_per_sta_mbps=" << offeredLoad
              << " offered_total_mbps=" << nSta * offeredLoad << " rng_run=" << rngRun
              << " MCS9 BCC NSS1 GI3200ns radius5m" << '\n';
    Simulator::Stop(Seconds(SETUP_DEADLINE + ACTIVE_TIME + 1.0));
    Simulator::Run();
    monitor->CheckForLostPackets();

    auto classifier = DynamicCast<Ipv4FlowClassifier>(flowHelper.GetClassifier());
    std::vector<std::array<Kpi, 2>> stationLink(nSta);
    bool countersOk = true;
    for (const auto& item : monitor->GetFlowStats())
    {
        const auto tuple = classifier->FindFlow(item.first);
        if (tuple.protocol != 17 || tuple.destinationAddress != apAddress ||
            (tuple.destinationPort != PORTS[0] && tuple.destinationPort != PORTS[1])) continue;
        auto station = sourceIndex.find(tuple.sourceAddress.Get());
        if (station == sourceIndex.end()) { countersOk = false; continue; }
        const uint8_t link = tuple.destinationPort == PORTS[0] ? 0 : 1;
        if (link >= nLinks) { countersOk = false; continue; }
        stationLink[station->second][link].AddFlow(item.second);
    }

    std::set<std::string> reasons;
    if (!topologyOk) reasons.insert("DEVICE_STRUCTURE");
    if (!mappingReady) reasons.insert("ASSOCIATION_MAPPING");
    if (sendErrors) reasons.insert("SOCKET_SEND_ERROR");
    if (!countersOk) reasons.insert("FLOW_CLASSIFICATION");
    if (unknownSource) reasons.insert("UNKNOWN_APP_SOURCE");
    for (uint32_t i = 0; i < nSta; ++i)
        if (!ArpOk(i)) reasons.insert("ARP_PEER_MAPPING");
    std::vector<Kpi> stationTotal(nSta);
    std::array<Kpi, 2> linkTotal;
    Kpi total;
    long double sumThroughput = 0, sumThroughputSquared = 0;
    for (uint32_t i = 0; i < nSta; ++i)
    {
        for (uint8_t link = 0; link < nLinks; ++link)
        {
            const auto& k = stationLink[i][link];
            if (k.rx > k.tx) reasons.insert("INVALID_COUNTERS");
            if (appRx[i][link] != k.rx) reasons.insert("APP_FLOW_RX_MISMATCH");
            if (sentOk[i][link] != k.tx) reasons.insert("APP_FLOW_TX_MISMATCH");
            stationTotal[i].Add(k);
            linkTotal[link].Add(k);
        }
        if (stationTotal[i].tx && !stationTotal[i].rx)
            std::cout << "WARN_ZERO_RX sta_id=" << i << '\n';
        total.Add(stationTotal[i]);
        const auto throughput = Throughput(stationTotal[i]);
        sumThroughput += throughput;
        sumThroughputSquared += throughput * throughput;
        auto staMac = DynamicCast<StaWifiMac>(devices[i + 1]->GetMac());
        if (staMac->GetSetupLinkIds().size() != nLinks) reasons.insert("FINAL_LINK_SETUP");
    }
    const std::string jain = sumThroughputSquared > 0
        ? Number(sumThroughput * sumThroughput / (nSta * sumThroughputSquared)) : "NA";
    const bool pass = reasons.empty();

    perSta << "case_id,demo,mode,n_sta,sta_id,offered_per_sta_mbps,"
        "tx_packets,rx_packets,rx_bytes,throughput_mbps,delay_ms,jitter_ms,loss_pct,"
        "throughput_5g_mbps,throughput_6g_mbps,setup_links,x_m,y_m,z_m\n";
    for (uint32_t i = 0; i < nSta; ++i)
    {
        auto staMac = DynamicCast<StaWifiMac>(devices[i + 1]->GetMac());
        const auto position = stas.Get(i)->GetObject<MobilityModel>()->GetPosition();
        perSta << caseId << ",5," << mode << ',' << nSta << ',' << i << ',' << offeredLoad << ',';
        WriteKpi(perSta, stationTotal[i]);
        perSta << ',' << Number(Throughput(stationLink[i][0]))
               << ',' << Number(Throughput(stationLink[i][1]))
               << ',' << staMac->GetSetupLinkIds().size()
               << ',' << position.x << ',' << position.y << ',' << position.z << '\n';
    }
    perLink << "case_id,demo,mode,phy_id,mac_link_id,band_ghz,width_mhz,"
        "offered_total_link_mbps,tx_packets,rx_packets,rx_bytes,throughput_mbps,"
        "delay_ms,jitter_ms,loss_pct\n";
    for (uint8_t link = 0; link < nLinks; ++link)
    {
        const auto macLink = devices[0]->GetMac()->GetLinkForPhy(link);
        perLink << caseId << ",5," << mode << ',' << +link << ','
                << (macLink ? std::to_string(*macLink) : "NA") << ',' << (link == 0 ? 5 : 6)
                << ",20," << nSta * offeredLoad / nLinks << ',';
        WriteKpi(perLink, linkTotal[link]);
        perLink << '\n';
    }

    DoubleValue txPower, noiseFigure;
    UintegerValue nss;
    TimeValue queueDelay;
    auto radio = devices[0]->GetPhy(0);
    radio->GetAttribute("TxPowerStart", txPower);
    noiseFigure.Set(7.0);
    radio->GetAttribute("MaxSupportedTxSpatialStreams", nss);
    auto queue = devices[1]->GetMac()->GetQosTxop(AC_BE)->GetWifiMacQueue();
    queueDelay.Set(queue->GetMaxDelay());
    const auto gi = devices[0]->GetHeConfiguration()->GetGuardInterval();

    summary << "schema,case_id,demo,mode,n_sta,offered_per_sta_mbps,offered_total_mbps,"
        "mcs,coding,nss,width5_mhz,width6_mhz,gi_ns,payload_bytes,seed,rng_run,"
        "app_start_s,sim_stop_s,measure_s,radius_m,pathloss,link_policy,tx_power_dbm,"
        "rx_noise_figure_db,queue_max_size,queue_max_delay_ms,tx_packets,rx_packets,"
        "rx_bytes,throughput_mbps,delay_ms,jitter_ms,loss_pct,throughput_5g_mbps,"
        "throughput_6g_mbps,jain_sta,status,reason,speed_mps,nakagami_m,mobility_model\n";
    summary << "2," << caseId << ",5," << mode << ',' << nSta << ',' << offeredLoad
            << ',' << nSta * offeredLoad << ",9,BCC," << nss.Get() << ",20,"
            << (nLinks == 2 ? 20 : 0) << ',' << gi.GetNanoSeconds() << ',' << PAYLOAD
            << ',' << seed << ',' << rngRun << ',' << APP_START << ',' << SIM_STOP
            << ',' << ACTIVE_TIME << ',' << RADIUS << ",LogDistance+Nakagami,"
            << (nLinks == 2 ? "EVEN_TID0_3_AC_BE" : "SINGLE_LINK")
            << ',' << txPower.Get() << ',' << noiseFigure.Get() << ',' << queue->GetMaxSize()
            << ',' << queueDelay.Get().GetSeconds() * 1000.0 << ',';
    WriteKpi(summary, total);
    summary << ',' << Number(Throughput(linkTotal[0]))
            << ',' << Number(Throughput(linkTotal[1])) << ',' << jain
            << ',' << (pass ? "PASS" : "FAIL") << ',' << JoinReasons(reasons)
            << ',' << speed << ',' << nakagamiM << ','
            << (speed > 0 ? "RandomWalk2d" : "ConstantPosition") << '\n';
    summary.flush();
    perSta.flush();
    perLink.flush();
    const bool ioOk = summary && perSta && perLink;
    std::cout << "RESULT," << caseId << ',' << (pass && ioOk ? "PASS" : "FAIL")
              << ",throughput_mbps=" << Number(Throughput(total))
              << ",loss_pct=" << Loss(total) << ",reason=" << JoinReasons(reasons) << '\n';
    for (auto& station : sources)
        for (uint8_t link = 0; link < nLinks; ++link) station[link]->Close();
    for (uint8_t link = 0; link < nLinks; ++link) sinks[link]->Close();
    Simulator::Destroy();
    return pass && ioOk ? 0 : 1;
}
