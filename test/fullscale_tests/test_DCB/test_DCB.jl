# SPDX-FileCopyrightText: 2023 Christian Willberg <christian.willberg@dlr.de>, Jan-Timo Hesse <jan-timo.hesse@dlr.de>
#
# SPDX-License-Identifier: BSD-3-Clause

folder_name = basename(@__FILE__)[1:(end - 3)]
cd("fullscale_tests/" * folder_name) do
    run_perilab("DCBmodel_unified_bb", 1, true, folder_name)
    run_perilab("DCBmodel_correspondence", 1, true, folder_name)
    run_perilab("DCBmodel_UMAT", 1, true, folder_name)
    run_perilab("DCBmodel_PD_solid", 1, true, folder_name)
    run_perilab("DCBmodel_PD_solid_local_damping", 1, true, folder_name)
    # run_perilab("DCBmodel_PD_solid_switch", 1, true, folder_name)
    run_perilab("DCBmodel_PD_solid_temp_depended", 1, true, folder_name)
    run_perilab("DCBmodel_correspondence_bond_associated", 1, true, folder_name)
    run_perilab("DCBmodel_correspondence_surface_correction", 1, true, folder_name)
end
