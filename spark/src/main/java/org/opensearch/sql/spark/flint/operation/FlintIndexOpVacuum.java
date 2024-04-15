/*
 * Copyright OpenSearch Contributors
 * SPDX-License-Identifier: Apache-2.0
 */

package org.opensearch.sql.spark.flint.operation;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.opensearch.sql.spark.flint.FlintIndexMetadata;
import org.opensearch.sql.spark.flint.FlintIndexMetadataService;
import org.opensearch.sql.spark.flint.FlintIndexState;
import org.opensearch.sql.spark.flint.FlintIndexStateModel;
import org.opensearch.sql.spark.flint.FlintIndexStateModelService;

/** Flint index vacuum operation. */
public class FlintIndexOpVacuum extends FlintIndexOp {

  private static final Logger LOG = LogManager.getLogger();

  /** OpenSearch client. */
  private final FlintIndexMetadataService flintIndexMetadataService;

  public FlintIndexOpVacuum(
      FlintIndexStateModelService flintIndexStateModelService,
      String datasourceName,
      FlintIndexMetadataService flintIndexMetadataService) {
    super(flintIndexStateModelService, datasourceName);
    this.flintIndexMetadataService = flintIndexMetadataService;
  }

  @Override
  boolean validate(FlintIndexState state) {
    return state == FlintIndexState.DELETED;
  }

  @Override
  FlintIndexState transitioningState() {
    return FlintIndexState.VACUUMING;
  }

  @Override
  public void runOp(FlintIndexMetadata flintIndexMetadata, FlintIndexStateModel flintIndex) {
    flintIndexMetadataService.deleteFlintIndex(flintIndexMetadata.getOpensearchIndexName());
  }

  @Override
  FlintIndexState stableState() {
    // Instruct StateStore to purge the index state doc
    return FlintIndexState.NONE;
  }
}
