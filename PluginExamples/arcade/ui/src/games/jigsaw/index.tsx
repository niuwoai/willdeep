import { useEffect, useMemo, useRef, useState } from 'react';
import type { CSSProperties, DragEvent } from 'react';
import type { GameProps } from '../../core/types';
import { saveBestScore } from '../../core/bestScore';
import { playCue } from '../../core/audio';
import { useI18n } from '../../core/i18n';
import { entropySeed } from '../../core/rng';
import { useAutoAdvance, useStageReport } from '../../core/stage';
import coastalLighthouse from './assets/coastal-lighthouse.webp';
import mountainRailway from './assets/mountain-railway.webp';
import moonlitGreenhouse from './assets/moonlit-greenhouse.webp';
import {
  createInitialState,
  gridForStage,
  restart,
  scoreFor,
  selectPosition,
  swapPositions,
} from './logic';
import type { JigsawState } from './logic';
import { jigsawStrings } from './strings';
import type { JigsawImageId } from './strings';
import './jigsaw.css';

interface JigsawImage {
  id: JigsawImageId;
  src: string;
}

const JIGSAW_IMAGES: readonly JigsawImage[] = [
  { id: 'lighthouse', src: coastalLighthouse },
  { id: 'railway', src: mountainRailway },
  { id: 'greenhouse', src: moonlitGreenhouse },
];

function pieceStyle(piece: number, grid: number, image: string): CSSProperties {
  const row = Math.floor(piece / grid);
  const column = piece % grid;
  const denominator = Math.max(1, grid - 1);
  return {
    backgroundImage: `url(${image})`,
    backgroundSize: `${grid * 100}% ${grid * 100}%`,
    backgroundPosition: `${(column / denominator) * 100}% ${(row / denominator) * 100}%`,
  };
}

export default function JigsawGame({ seed, onWin, onStage }: GameProps) {
  const { locale } = useI18n();
  const strings = jigsawStrings(locale);
  const baseSeed = useMemo(() => seed ?? entropySeed('jigsaw'), [seed]);
  const [imageId, setImageId] = useState<JigsawImageId | null>(null);
  const [stage, setStage] = useState(1);
  const [total, setTotal] = useState(0);
  const [showPreview, setShowPreview] = useState(false);
  const [dragFrom, setDragFrom] = useState<number | null>(null);
  const grid = gridForStage(stage);
  const [state, setState] = useState<JigsawState>(() => createInitialState(grid, `${baseSeed}@1`));
  const wonHandled = useRef(false);
  const selectedImage = JIGSAW_IMAGES.find((image) => image.id === imageId) ?? null;

  useEffect(() => {
    if (!imageId) return;
    wonHandled.current = false;
    setState(createInitialState(gridForStage(stage), `${baseSeed}@${imageId}@${stage}`));
  }, [baseSeed, imageId, stage]);

  useStageReport(onStage, {
    stage,
    score: total,
    label: imageId ? `${grid}×${grid} · ${strings.imageNames[imageId]}` : strings.chooseTitle,
  });

  useAutoAdvance(state.status === 'won' && imageId !== null, () => setStage((current) => current + 1));

  useEffect(() => {
    if (state.status !== 'won' || wonHandled.current) return;
    wonHandled.current = true;
    const gained = scoreFor(state.grid, state.moves);
    setTotal((current) => {
      const next = current + gained;
      saveBestScore('jigsaw', next);
      return next;
    });
    playCue('win');
    onWin?.();
  }, [onWin, state.grid, state.moves, state.status]);

  const chooseImage = (nextImage: JigsawImageId): void => {
    playCue('select');
    setImageId(nextImage);
    setStage(1);
    setTotal(0);
    setShowPreview(false);
    wonHandled.current = false;
    setState(createInitialState(gridForStage(1), `${baseSeed}@${nextImage}@1`));
  };

  const handlePosition = (position: number): void => {
    playCue('select');
    setState((current) => selectPosition(current, position));
  };

  const handleDrop = (event: DragEvent<HTMLButtonElement>, position: number): void => {
    event.preventDefault();
    const encoded = event.dataTransfer.getData('text/plain');
    const from = dragFrom ?? Number(encoded);
    setDragFrom(null);
    if (!Number.isInteger(from)) return;
    playCue('select');
    setState((current) => swapPositions(current, from, position));
  };

  if (!selectedImage) {
    return (
      <section className="jigsaw jigsaw--picker" data-testid="jigsaw-game">
        <header className="jigsaw__picker-header">
          <h2>{strings.chooseTitle}</h2>
          <p>{strings.chooseHint}</p>
        </header>
        <div className="jigsaw__gallery" data-testid="jigsaw-picker">
          {JIGSAW_IMAGES.map((image) => (
            <button
              key={image.id}
              type="button"
              className="jigsaw__choice"
              data-testid={`jigsaw-image-${image.id}`}
              onClick={() => chooseImage(image.id)}
              aria-label={`${strings.chooseImage}: ${strings.imageNames[image.id]}`}
            >
              <img src={image.src} alt={strings.imageDescriptions[image.id]} />
              <strong>{strings.imageNames[image.id]}</strong>
              <span>{strings.imageDescriptions[image.id]}</span>
            </button>
          ))}
        </div>
      </section>
    );
  }

  const statusText: Record<JigsawState['status'], string> = {
    idle: strings.statusIdle,
    playing: strings.statusPlaying,
    won: strings.statusWon,
  };

  return (
    <section className="jigsaw" data-testid="jigsaw-game">
      <div className="jigsaw__bar">
        <span data-testid="jigsaw-stage">{strings.stageLabel} {stage} · {grid}×{grid}</span>
        <span data-testid="jigsaw-moves">{strings.moves}: {state.moves}</span>
        <span data-testid="jigsaw-total">{strings.totalLabel}: {total}</span>
        <span className="jigsaw__status" data-testid="jigsaw-status">{statusText[state.status]}</span>
      </div>

      <div className="jigsaw__tools">
        <button
          type="button"
          className="btn"
          data-testid="jigsaw-restart"
          onClick={() => {
            playCue('shuffle');
            wonHandled.current = false;
            setState(restart);
          }}
        >
          {strings.restart}
        </button>
        <button
          type="button"
          className="btn btn--ghost"
          data-testid="jigsaw-restart-run"
          onClick={() => {
            playCue('select');
            setTotal(0);
            setStage(1);
            wonHandled.current = false;
            setState(createInitialState(gridForStage(1), `${baseSeed}@${imageId}@1`));
          }}
        >
          {strings.restartRun}
        </button>
        <button
          type="button"
          className="btn btn--ghost"
          data-testid="jigsaw-preview-toggle"
          aria-pressed={showPreview}
          onClick={() => setShowPreview((current) => !current)}
        >
          {showPreview ? strings.hidePreview : strings.preview}
        </button>
        <button
          type="button"
          className="btn btn--ghost"
          data-testid="jigsaw-change-image"
          onClick={() => {
            playCue('select');
            setImageId(null);
            setTotal(0);
            setStage(1);
          }}
        >
          {strings.changeImage}
        </button>
      </div>

      {showPreview && (
        <figure className="jigsaw__preview" data-testid="jigsaw-preview">
          <img src={selectedImage.src} alt={strings.imageDescriptions[selectedImage.id]} />
          <figcaption>{strings.imageNames[selectedImage.id]}</figcaption>
        </figure>
      )}

      <div
        className="jigsaw__board"
        data-testid="jigsaw-board"
        role="grid"
        aria-label={strings.boardLabel}
        style={{ '--jigsaw-grid': grid } as CSSProperties}
      >
        {state.order.map((piece, position) => (
          <button
            key={piece}
            type="button"
            role="gridcell"
            className={[
              'jigsaw__piece',
              state.selected === position ? 'jigsaw__piece--selected' : '',
              piece === position ? 'jigsaw__piece--correct' : '',
            ].filter(Boolean).join(' ')}
            style={pieceStyle(piece, grid, selectedImage.src)}
            data-testid="jigsaw-piece"
            data-piece={piece}
            data-position={position}
            aria-pressed={state.selected === position}
            aria-label={strings.pieceLabel
              .replace('{piece}', String(piece + 1))
              .replace('{position}', String(position + 1))}
            draggable={state.status !== 'won'}
            disabled={state.status === 'won'}
            onClick={() => handlePosition(position)}
            onDragStart={(event) => {
              setDragFrom(position);
              event.dataTransfer.setData('text/plain', String(position));
              event.dataTransfer.effectAllowed = 'move';
            }}
            onDragOver={(event) => event.preventDefault()}
            onDrop={(event) => handleDrop(event, position)}
            onDragEnd={() => setDragFrom(null)}
          />
        ))}
      </div>

      <p className="jigsaw__hint">{strings.hint}</p>
    </section>
  );
}
