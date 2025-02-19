# SPDX-FileCopyrightText: 2023 Christian Willberg <christian.willberg@dlr.de>, Jan-Timo Hesse <jan-timo.hesse@dlr.de>
#
# SPDX-License-Identifier: BSD-3-Clause



folder_name = basename(@__FILE__)[1:end-3]
cd("fullscale_tests/" * folder_name) do
    run_perilab("test_static_bond_based_elastic_2D", 1, true, folder_name)
    run_perilab("test_bond_based_elastic_2D", 1, true, folder_name)
    run_perilab("test_bond_based_elastic_3D", 1, true, folder_name)
    run_perilab("test_bond_based_elastic_3D", 3, true, folder_name)
    run_perilab("test_bond_based_elastic_4_points", 2, true, folder_name)
    run_perilab("test_unified_bond_based_elastic_2D", 1, true, folder_name)
    run_perilab("test_unified_bond_based_elastic_3D", 1, true, folder_name)

end
