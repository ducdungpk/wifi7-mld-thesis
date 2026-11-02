// SPDX-License-Identifier: GPL-2.0-only
//
// Unified entry point for the archived foundation D1/D2/D4 checks.
// ns3_prepare.sh restores the original C++ bytes into .inc files.
//
// No simulation logic is rewritten in this entry point.

#include "ns3/core-module.h"
#include "ns3/flow-monitor-module.h"
#include "ns3/internet-module.h"
#include "ns3/mobility-module.h"
#include "ns3/network-module.h"
#include "ns3/spectrum-module.h"
#include "ns3/wifi-module.h"
#include "ns3/udp-header.h"
#include "ns3/net-device-queue-interface.h"

#include <optional>
#include <tuple>
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

namespace PrecheckD1
{
#define main RunFoundation
#include "ns3-precheck-sources/foundation-d1.inc"
#undef main
}

namespace PrecheckD2
{
#define main RunFoundation
#include "ns3-precheck-sources/foundation-d2.inc"
#undef main
}

namespace PrecheckD4
{
#define main RunFoundation
#include "ns3-precheck-sources/foundation-d4.inc"
#undef main
}

int
main(int argc, char* argv[])
{
    std::string program;
    std::vector<char*> forwarded{argv[0]};

    for (int i = 1; i < argc; ++i)
    {
        const std::string argument(argv[i]);

        if (argument.rfind("--program=", 0) == 0)
        {
            if (!program.empty())
            {
                std::cerr << "Duplicate --program argument\n";
                return 2;
            }

            program = argument.substr(10);
        }
        else
        {
            forwarded.push_back(argv[i]);
        }
    }

    if (program != "1" && program != "2" && program != "4")
    {
        std::cerr
            << "Use --program=1, --program=2 or --program=4, "
            << "followed by the original foundation arguments.\n";

        return 2;
    }

    const int count = static_cast<int>(forwarded.size());
    forwarded.push_back(nullptr);

    if (program == "1")
    {
        return PrecheckD1::RunFoundation(
            count,
            forwarded.data());
    }

    if (program == "2")
    {
        return PrecheckD2::RunFoundation(
            count,
            forwarded.data());
    }

    return PrecheckD4::RunFoundation(
        count,
        forwarded.data());
}